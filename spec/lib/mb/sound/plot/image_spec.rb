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

  it 'wraps a legend that does not fit beside the title onto rows under it' do
    long = MB::Sound::Plot.figure { chart(title: 'a rather long chart title here') { y(-1..5); 5.times { |i| line(Numo::DFloat[0, i], label: "series number #{i}") } } }
    short = MB::Sound::Plot.figure { chart(title: 'a rather long chart title here', legend: false) { y(-1..5); line(Numo::DFloat[0, 1]) } }
    svg_long = long.to_svg(width: 400, height: 300)
    svg_short = short.to_svg(width: 400, height: 300)
    top = ->(svg) { svg[/clipPath id="[^"]*"><rect[^>]*>/] && svg[/<g transform="translate\(\S+ (\S+)\)" clip-path/, 1].to_f }
    expect(top.(svg_long)).to be > top.(svg_short) + 20 # legend rows push the plot down
  end
end
