require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::SpectralMotion) do
  let(:sm) { MB::Sound::Analysis::SpectralMotion }
  let(:noise) { SyntheticSounds.noise(1) }

  it 'follows a resonant peak falling from 4 kHz to 1 kHz' do
    swept = SyntheticSounds.bandpass(noise, SyntheticSounds.sweep(4000, 1000, noise.length), 10) + noise * 0.05
    r = sm.new(swept).resonance
    expect(r.motion).to eq(:falling)
    expect(r.from.frequency).to be_within(400).of(4000)
    expect(r.to.frequency).to be_within(150).of(1000)
    expect(r.octaves).to be_within(0.3).of(-2)
    expect(r.prominence).to be > 6
    expect(r.to_s).to match(/a resonant peak falling from 3\.\d kHz to 1\.\d kHz/)
  end

  it 'reads a standing resonance as static' do
    still = SyntheticSounds.bandpass(noise, Numo::DFloat.new(noise.length).fill(2000), 10) + noise * 0.05
    r = sm.new(still).resonance
    expect(r.motion).to eq(:static)
    expect(r.from.frequency).to be_within(150).of(2000)
  end

  it 'finds a resonant lowpass on a saw through its harmonics' do
    r = sm.new(MB::Sound::Analysis::Signal.from(MB::Sound::Pitch.new(110).saw.filter(:lowpass, cutoff: 800, quality: 8), seconds: 1)).resonance
    expect(r.motion).to eq(:static)
    expect(r.from.frequency).to be_within(80).of(800)
    expect(sm.new(MB::Sound::Analysis::Signal.from(MB::Sound::Pitch.new(110).saw.filter(:lowpass, cutoff: 800, quality: 0.7), seconds: 1)).resonance).to be_nil
  end

  it 'finds comb teeth sliding as a flanger sweeps from 1 to 5 ms' do
    delays = 0.001 + 0.004 * Numo::DFloat.new(noise.length).seq / noise.length
    c = sm.new(SyntheticSounds.flanger(noise, delays)).comb
    expect(c.motion).to eq(:sliding_down)
    expect(c.delay_from.to_f).to be_within(0.0004).of(0.0012)
    expect(c.delay_to.to_f).to be_within(0.0005).of(0.0048)
    expect(c.to_s).to include('comb teeth sliding down', 'a flanger sweep?')
  end

  it 'reads a fixed delay as a static comb' do
    c = sm.new(SyntheticSounds.flanger(noise, Numo::DFloat.new(noise.length).fill(0.0025))).comb
    expect(c.motion).to eq(:static)
    expect(c.delay_from.to_f).to be_within(0.0001).of(0.0025)
  end

  it 'finds neither in plain noise or a plain harmonic tone' do
    [noise, SyntheticSounds.tone(220, 1, harmonics: 30)].each do |x|
      m = sm.new(x)
      expect(m.resonance).to be_nil
      expect(m.comb).to be_nil
      expect(m.to_s).to eq('no moving or standing resonant peak; no comb teeth')
    end
  end
end
