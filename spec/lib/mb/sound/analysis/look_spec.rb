require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Look) do
  # Width and height from a PNG's IHDR chunk.
  def png_size(path)
    File.binread(path, 24)[16, 8].unpack('NN')
  end

  it 'writes a PNG with a column per sound and four rows' do
    path = tmp_path('look.png')
    out = MB::Sound::Analysis.look({ 'target' => SyntheticSounds.tone(220, 0.5), 'fit' => SyntheticSounds.tone(220, 0.5, harmonics: 4) }, path: path)
    expect(out).to eq(path)
    expect(File.binread(path, 8)).to eq("\x89PNG\r\n\x1A\n".b)
    expect(png_size(path)).to eq([1400, 920])
  end

  it 'draws one sound in one column, with labeled rows' do
    fig = MB::Sound::Analysis::Look.figure(SyntheticSounds.tone(220, 0.3))
    svg = fig.to_svg(width: 700, height: 920)
    expect(svg).to include('target: waveform (0.300 s)', 'target: first 50 ms', 'target: spectrogram', 'target: top 3 octaves')
    expect(svg).to include('time', 'frequency')
    path = tmp_path('one.png')
    MB::Sound::Analysis::Look.save(path, SyntheticSounds.tone(220, 0.3), width: 500, height: 600)
    expect(png_size(path)).to eq([500, 600])
  end

  it 'labels sounds by name, Hash key, or position' do
    s = MB::Sound::Analysis::Look.signals([SyntheticSounds.sine(220, 0.1), MB::Sound::Analysis::Signal.new(SyntheticSounds.sine(330, 0.1), name: 'named')])
    expect(s.keys).to eq(['target', 'named'])
    expect(MB::Sound::Analysis::Look.signals({ 'a' => SyntheticSounds.sine(220, 0.1) }).keys).to eq(['a'])
  end
end
