RSpec.describe(MB::Sound::Plot::Text) do
  let(:plot) { MB::Sound::Plot }
  let(:ramps) { plot.chart(title: 'ramp') { line [0, 1, 2, 3, 4], label: 'up'; line [4, 3, 2, 1, 0], label: 'down' } }

  it 'draws the same ASCII text every time' do
    expected = <<~TEXT.chomp
      ramp                      -- up  -- down
      4+'--..                            ..--'
      3+     '|-..                  ..-|'     
       |          ''--..      ..--''          
      2+                ':||:'                
       |           ..--''    ''--..           
      1+      .--''                ''--.      
      0+..--''                          ''--..
       ++--------+---------+--------+--------+
        0        1         2        3        4
    TEXT
    expect(ramps.to_s(width: 40, height: 10, look: :ascii)).to eq(expected)
  end

  described_class::LOOKS.each_key do |look|
    it "fills exactly the requested size with the #{look} look" do
      [[40, 10], [97, 23], [12, 4]].each do |w, h|
        lines = ramps.lines(width: w, height: h, look: look, color: :none)
        expect(lines.length).to eq(h)
        expect(lines.map(&:length).uniq).to eq([w])
      end
    end
  end

  it 'survives tiny sizes' do
    [[4, 1], [5, 2], [8, 3], [20, 2]].each do |w, h|
      expect(ramps.lines(width: w, height: h, color: :none).length).to eq(h)
    end
  end

  it 'uses Braille, block, sextant, and eighth-block characters' do
    wave = plot.waveform(100.hz.ramp.sample(4800))
    expect(wave.to_s(width: 60, height: 12, look: :scope, color: :none)).to match(/[⠁-⣿]/)
    expect(wave.to_s(width: 60, height: 12, look: :blocks, color: :none)).to match(/[▀▄█]/)
    expect(wave.to_s(width: 60, height: 12, look: :mosaic, color: :none)).to match(/[\u{1fb00}-\u{1fb3b}▌▐]/)
    expect(wave.to_s(width: 60, height: 12, look: :spark, color: :none)).to match(/[▁▂▃▄▅▆▇]/)
  end

  it 'writes truecolor, 256-color, and 16-color codes, and none when asked' do
    expect(ramps.to_s(width: 40, height: 10, color: :truecolor)).to include("\e[38;2;")
    expect(ramps.to_s(width: 40, height: 10, color: :ansi256)).to match(/\e\[38;5;\d+m/)
    expect(ramps.to_s(width: 40, height: 10, color: :ansi16)).to match(/\e\[9\dm/)
    expect(ramps.to_s(width: 40, height: 10, color: :none)).not_to include("\e")
  end

  it 'colors series in palette order with the legend matching' do
    text = ramps.to_s(width: 40, height: 10, color: :truecolor, theme: :dark)
    up, down = plot::THEMES[:dark].palette.first(2)
    expect(text).to include("\e[38;2;#{up.join(';')}m━━\e[0m up")
    expect(text).to include("\e[38;2;#{down.join(';')}m━━\e[0m down")
  end

  it 'shades heatmaps without color and adds a colorbar' do
    z = Numo::DFloat.new(10, 20).seq
    text = plot.chart(title: 'ramp') { heatmap z }.to_s(width: 50, height: 14, color: :none)
    expect(text).to include('░', '▓', '█')
    expect(text.lines[1]).to match(/██ *\d/)
  end

  it 'draws heatmaps as half blocks with two colors per cell' do
    z = Numo::DFloat.new(10, 20).seq
    text = plot.chart(title: 'ramp') { heatmap z }.to_s(width: 50, height: 14, color: :truecolor)
    expect(text).to match(/\e\[38;2;[\d;]+;48;2;[\d;]+m▀/)
  end

  it 'keeps polar plots square with rings' do
    t = Numo::DFloat.linspace(0, 1, 200)
    c = plot.chart { polar; line t * 0 + 0.8, x: t }
    lines = c.lines(width: 80, height: 20, look: :scope, color: :none)
    used = lines.map { |l| l.index(/[^ ]/) }.compact.min
    expect(used).to be >= 15
  end

  it 'puts the x axis title with its unit ahead of tick labels' do
    text = plot.waveform(100.hz.sample(4800)).to_s(width: 50, height: 10, color: :none)
    expect(text.lines.last).to end_with('time (ms)')
  end

  it 'adds a note-name row under frequency axes' do
    text = plot.spectrum(440.hz.ramp.sample(4096)).to_s(width: 100, height: 20, color: :none)
    expect(text.lines.last).to include('C3', 'C5')
    expect(text).to include('frequency (Hz)', '1k')
  end

  it 'wraps legends that do not fit beside the title onto rows of their own' do
    c = plot.chart(title: 'a long title for a narrow chart') { line [1, 2], label: 'first series'; line [2, 1], label: 'second series'; line [1, 1], label: 'third' }
    lines = c.lines(width: 34, height: 12, color: :none)
    expect(lines[0]).to start_with('a long title')
    expect(lines[1]).to start_with('━━ first series  ━━ second series')
    expect(lines[2]).to start_with('━━ third')
    expect(lines.length).to eq(12)
  end

  it 'leaves out legend rows that would crowd out the plot' do
    c = plot.chart(title: 'title') { 8.times { |i| line [i, i + 1], label: "series #{i}" } }
    lines = c.lines(width: 20, height: 9, color: :none)
    expect(lines.count { |l| l.start_with?('━━') }).to eq(2)
    expect(lines.length).to eq(9)
  end
end
