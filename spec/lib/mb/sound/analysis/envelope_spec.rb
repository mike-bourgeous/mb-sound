require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Envelope) do
  let(:env) { MB::Sound::Analysis::Envelope }

  it 'reads a kick as percussive, with decay times and a fade' do
    e = env.new(SyntheticSounds.kick)
    expect(e.shape).to eq(:percussive)
    expect(e.peak_time.to_f).to be < 0.01
    # 12/s decay: 20 dB in ln(10)/12 s, from the peak
    expect(e.decay[20].to_f).to be_within(0.02).of(Math.log(10) / 12)
    expect(e.decay[6].to_f).to be < e.decay[20].to_f
    expect(e.ending).to eq(:fade)
    expect(e.brightness_motion).to eq(:falling)
    expect(e.to_s).to include('percussive', 'fades out', 'brightness falls')
  end

  it 'reads the same kick backward as a swell that cuts off, brightening' do
    e = env.new(SyntheticSounds.kick.reverse.dup)
    expect(e.shape).to eq(:swell)
    expect(e.ending).to eq(:cut)
    expect(e.brightness_motion).to eq(:rising)
    expect(e.to_s).to include('swells (peaks late)', 'cut off while loud', 'brightness rises')
  end

  it 'reads a held tone as sustained and steady' do
    e = env.new(SyntheticSounds.tone(220, 1))
    expect(e.shape).to eq(:sustained)
    expect(e.brightness_motion).to eq(:steady)
    expect(e.to_h[:shape]).to eq(:sustained)
  end
end
