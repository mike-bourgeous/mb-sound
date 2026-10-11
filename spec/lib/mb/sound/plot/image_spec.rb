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
end
