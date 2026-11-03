require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Signal) do
  let(:sig) { MB::Sound::Analysis::Signal }

  it 'takes audio data, mixes channels, and keeps a frozen copy' do
    a = SyntheticSounds.sine(440, 0.1)
    s = sig.from([a, a * 0.5])
    expect(s.length).to eq(a.length)
    expect(s.data).to be_frozen
    expect(s.data[100]).to be_within(1e-12).of(a[100] * 0.75)
    expect(s.seconds).to be_within(1e-12).of(0.1)
  end

  it 'resamples other rates to 48 kHz' do
    t = Numo::DFloat.new(4410).seq / 44100
    s = sig.from(Numo::NMath.sin(t * 2 * Math::PI * 1000), sample_rate: 44100)
    expect(s.length).to eq(4800)
    expect(s.source_rate).to eq(44100)
    expect(MB::Sound.freq_estimate(s.data[1000...4000], range: 500..2000)).to be_within(5).of(1000)
  end

  it 'reads files and Samples' do
    path = tmp_path('tone.flac')
    MB::Sound.write(path, [SyntheticSounds.sine(220, 0.3)])
    s = sig.from(path)
    expect(s.name).to eq('tone')
    expect(s.seconds).to be_within(0.001).of(0.3)
    expect(sig.from(path, seconds: 0.1).seconds).to be_within(0.001).of(0.1)

    smp = MB::Sound::Sample.new([SyntheticSounds.sine(220, 0.2)], name: 'smp')
    expect(sig.from(smp).seconds).to be_within(0.001).of(0.2)
  end

  it 'renders graphs for seconds:, or until they end (at most GRAPH_SECONDS)' do
    s = sig.from(220.hz.sine, seconds: 0.25)
    expect(s.length).to eq(12000)
    expect(s.truncated).to eq(false)
    expect(s.peak).to be_within(0.01).of(1.0) # no master gain

    stub_const('MB::Sound::Analysis::Signal::GRAPH_SECONDS', 0.1)
    expect(sig.from(220.hz.sine).truncated).to eq(true)

    ended = sig.from(220.hz.sine.until(0.05))
    expect(ended.truncated).to eq(false)
    expect(ended.seconds).to be <= 0.1
  end

  it 'aligns the onset to sample ONSET' do
    d = Numo::DFloat.zeros(1000).concatenate(SyntheticSounds.sine(440, 0.1))
    s = sig.from(d)
    expect(s.onset).to be_between(1000, 1010)
    expect(s.aligned.onset).to eq(sig::ONSET)
  end

  it 'keeps STFTs and envelopes' do
    s = sig.from(SyntheticSounds.sine(1000, 0.2))
    expect(s.stft(1024, 240)).to equal(s.stft(1024, 240))
    expect(s.stft(1024, 240).shape).to eq([(s.length / 240.0).ceil, 513])
    env = s.envelope_db(240)
    expect(env.length).to eq(40)
    expect(env[20]).to be_within(0.1).of(20 * Math.log10(0.5 / Math.sqrt(2)))
  end

  it 'finds the band of a sound between 2 and 16 kHz' do
    expect(sig.from(SyntheticSounds.tone(220, 0.5, harmonics: 10)).band).to be_between(2200, 4500)
    expect(sig.from(SyntheticSounds.noise(0.5)).band).to eq(16000.0)
  end
end
