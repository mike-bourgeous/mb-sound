RSpec.describe(MB::Sound::Plot::Presets) do
  it 'reads a full-scale sine at 0 dB at its frequency' do
    freq = 171 * 48000.0 / 8192 # on a bin (no scalloping loss)
    f, db = described_class.spectrum_db(Numo::DFloat.cast(freq.hz.sine.sample(8192)), 48000, -120)
    k = db.max_index
    expect(f[k]).to be_within(0.01).of(freq)
    expect(db.max).to be_within(0.2).of(0)
  end

  it 'makes spectrogram rows of bins and columns of frames' do
    z, top = described_class.stft_db(Numo::DFloat.cast(500.hz.sine.sample(8192)), 1024, 256, -90)
    expect(z.shape).to eq([512, 29])
    expect(top).to eq(0)
    expect(z[true, 10].max_index).to be_within(1).of((500 / (48000.0 / 1024)).round - 1)
  end

  it 'charts channels from arrays, Hashes, and 2D arrays' do
    expect(MB::Sound::Plot.waveform([Numo::SFloat[1, -1], Numo::SFloat[0, 1]]).marks.map(&:label)).to eq(%w[0 1])
    expect(MB::Sound::Plot.waveform({ left: [1, 2] }).marks.map(&:label)).to eq(['left'])
    expect(MB::Sound::Plot.waveform(Numo::SFloat.zeros(2, 10)).marks.length).to eq(2)
    expect(MB::Sound::Plot.envelope([0, 1, 0.5], db: 60).coord.y.lo).to eq(-60)
  end

  it 'charts spectrograms with a dB colorbar scale and note names' do
    c = MB::Sound::Plot.spectrogram(Numo::DFloat.cast(440.hz.ramp.sample(9600)), fft: 512)
    expect(c.heatmap.z_scale).to be_a(MB::Sound::Plot::Scale::DB)
    expect(c.coord.y).to be_a(MB::Sound::Plot::Scale::Frequency)
    expect(c.coord.y.secondary_ticks.map(&:label)).to include('C5')
  end
end
