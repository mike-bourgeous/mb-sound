require 'zlib'

RSpec.describe(MB::Sound::Plot::Image) do
  let(:chart) { MB::Sound::Plot.waveform(200.hz.ramp.sample(4800), title: 'saw') }

  it 'renders a PNG of the requested size' do
    png = chart.to_png(width: 320, height: 180)
    expect(png).to start_with("\x89PNG\r\n\x1a\n".b)
    expect(png[16, 8].unpack('NN')).to eq([320, 180])
  end

  it 'encodes PNG rows that decode back to the pixels' do
    rgb = Numo::UInt8.new(2, 3, 3).seq
    png = described_class.encode_png(rgb)
    idat = png[png.index('IDAT') + 4..][0, png[png.index('IDAT') - 4, 4].unpack1('N')]
    raw = Zlib::Inflate.inflate(idat).bytes
    expect(raw).to eq([0] + (0...9).to_a + [0] + (9...18).to_a)
  end

  it 'draws the theme background, axes, and lines' do
    img = described_class.render(chart.figure, width: 200, height: 120, theme: :studio)
    rgb = img.rgb
    bg = MB::Sound::Plot::Theme[:studio].background
    expect(rgb[0, 0, true].to_a).to eq(bg)
    line = MB::Sound::Plot::Theme[:studio].series(0)
    close = ((Numo::Int32.cast(rgb) - Numo::Int32[*line].reshape(1, 1, 3)).abs.max(axis: 2) < 30)
    expect(close.count_true).to be > 100
  end

  it 'encodes sixel images' do
    rgb = Numo::UInt8.zeros(12, 4, 3)
    rgb[0...6, true, 0] = 255
    six = described_class::Sixel.encode(rgb)
    expect(six).to start_with("\eP0;1;0q\"1;1;4;12").and end_with("\e\\")
    expect(six).to include('#210;2;100;0;0') # red
    expect(six.count('-')).to eq(2)
  end

  it 'has glyphs for ASCII and µ' do
    expect(described_class::Font.alpha('A').shape).to eq([16, 8])
    expect(described_class::Font.alpha('A').max).to be > 0.9
    expect(described_class::Font.alpha('µ').sum).to be > 1
    expect(described_class::Font.alpha('☃')).to eq(described_class::Font.alpha('?'))
  end

  it 'draws common non-ASCII punctuation and accented letters with ASCII stand-ins' do
    font = described_class::Font
    expect(font.alpha('—')).to eq(font.alpha('-'))
    expect(font.alpha('’')).to eq(font.alpha("'"))
    expect(font.alpha('“')).to eq(font.alpha('"'))
    expect(font.alpha('×')).to eq(font.alpha('x'))
    expect(font.alpha('é')).to eq(font.alpha('e'))
    expect(font.fallback('µ')).to eq('µ') # the font has it
    expect(font.fallback('☃')).to eq('?')
  end

  it 'keeps lines beyond the y domain inside their plot area' do
    data = Numo::DFloat.linspace(0, 1, 400).map { |t| Math.sin(t * 20) * 3 }
    fig = MB::Sound::Plot.figure do
      chart(title: 'top') { y(-1..1); line(data) }
      chart(title: 'bottom') { y(-1..1); line(data * 0) }
    end
    theme = MB::Sound::Plot::Theme[:paper]
    rgb = described_class.render(fig, width: 300, height: 300, theme: theme).rgb
    line = theme.series(0)
    near = ((Numo::Int32.cast(rgb) - Numo::Int32[*line].reshape(1, 1, 3)).abs.max(axis: 2) < 40)
    rows = near.count_true(axis: 1).to_a
    # The flat line in the bottom chart is the only series color below the
    # top chart: no spill from the top chart's +-3 swings over its title
    spill = rows[150...300].each_with_index.select { |c, _| c > 0 }.map(&:last)
    expect(spill.length).to be <= 4
    expect(rows[0...4].sum).to eq(0) # nothing over the top title row's top
  end

  # omnibus6: stems (and every other mark) whose data leaves the y domain
  # stay in their plot area, in PNG and SVG.
  describe 'marks beyond the domain' do
    far = Numo::DFloat[-5, 3, -0.5, 20, -100, 0.5]
    marks = {
      stems: ->(c) { c.stems(far, color: '#ff00ff') },
      stems_on_the_floor: ->(c) { c.stems(far, base: -1, color: '#ff00ff') },
      line: ->(c) { c.line(far, color: '#ff00ff') },
      points: ->(c) { c.points(far, color: '#ff00ff') },
      area: ->(c) { c.area(far, color: '#ff00ff') },
      band: ->(c) { c.band(far, far.abs + 1, color: '#ff00ff') },
      rules: ->(c) { c.rule(y: 3, color: '#ff00ff'); c.rule(y: -3, color: '#ff00ff'); c.rule(x: 9, color: '#ff00ff'); c.rule(y: 0.5, color: '#ff00ff') },
      heatmap: ->(c) { c.heatmap(Numo::DFloat.new(4, 4).seq, x: -2..8, y: -3..3) },
    }

    # Three charts in a column, the middle one with +mark+ (or nothing).
    def column_figure(mark)
      MB::Sound::Plot.figure(columns: 1) do
        chart(title: 'top') { x(0..5); y(-1..1); line(Numo::DFloat[0, 0.5]) }
        chart(title: 'middle') { |c| c.x(0..5); c.y(-1..1); mark&.call(c) }
        chart(title: 'bottom') { x(0..5); y(-1..1); line(Numo::DFloat[0, 0.5]) }
      end
    end

    # [row range, column range] of the pixels where +a+ and +b+ differ.
    def changed(a, b)
      d = (Numo::Int32.cast(a) - Numo::Int32.cast(b)).abs.max(axis: 2).gt(0)
      rows = d.count_true(axis: 1).gt(0).where
      cols = d.count_true(axis: 0).gt(0).where
      [rows.min..rows.max, cols.min..cols.max]
    end

    let(:theme) { MB::Sound::Plot::Theme[:paper] }
    let(:empty) { described_class.render(column_figure(nil), width: 300, height: 600, theme: theme).rgb }
    # The middle plot area: where a band over the whole domain draws
    let(:area) {
      full = ->(c) { c.band(Numo::DFloat.new(6).fill(-1), Numo::DFloat.new(6).fill(1), color: '#ff00ff') }
      changed(described_class.render(column_figure(full), width: 300, height: 600, theme: theme).rgb, empty)
    }

    marks.each do |name, mark|
      it "keeps #{name} inside the plot area in PNG" do
        # A heatmap adds a colorbar (a narrower plot), so it is compared with
        # the same heatmap placed inside the domain
        base = name == :heatmap ? described_class.render(column_figure(->(c) { c.heatmap(Numo::DFloat.new(4, 4).seq, x: 0..5, y: -1..1) }), width: 300, height: 600, theme: theme).rgb : empty
        rows, cols = changed(described_class.render(column_figure(mark), width: 300, height: 600, theme: theme).rgb, base)
        expect(rows.min).to be >= area[0].min - 3
        expect(rows.max).to be <= area[0].max + 3
        expect(cols.min).to be >= area[1].min - 3
        expect(cols.max).to be <= area[1].max + 3
      end

      it "draws #{name} only inside the middle plot's clip group in SVG" do
        svg = column_figure(mark).to_svg(width: 300, height: 600, theme: :paper)
        groups = svg.enum_for(:scan, /<g transform="translate\([^)]*\)" clip-path="url\(#[^)]*\)">/).map { Regexp.last_match.end(0) }
        expect(groups.length).to eq(3)
        start = groups[1]
        stop = svg.index('</g>', start)
        marker = name == :heatmap ? '<image' : '#ff00ff'
        hits = svg.enum_for(:scan, marker).map { Regexp.last_match.begin(0) }
        expect(hits).not_to be_empty
        expect(hits).to all(be_between(start, stop))
      end
    end
  end

  it 'wraps a legend that does not fit beside the title onto rows under it' do
    long = MB::Sound::Plot.figure { chart(title: 'a rather long chart title here') { y(-1..5); 5.times { |i| line(Numo::DFloat[0, i], label: "series number #{i}") } } }
    short = MB::Sound::Plot.figure { chart(title: 'a rather long chart title here', legend: false) { y(-1..5); line(Numo::DFloat[0, 1]) } }
    svg_long = long.to_svg(width: 400, height: 300)
    svg_short = short.to_svg(width: 400, height: 300)
    top = ->(svg) { svg[/clipPath id="[^"]*"><rect[^>]*>/] && svg[/<g transform="translate\(\S+ (\S+)\)" clip-path/, 1].to_f }
    expect(top.(svg_long)).to be > top.(svg_short) + 20 # legend rows push the plot down
  end
end
