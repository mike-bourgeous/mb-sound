require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::PitchEnvelope) do
  let(:pe) { MB::Sound::Analysis::PitchEnvelope }

  it 'follows a kick drop cycle by cycle' do
    e = pe.of(SyntheticSounds.kick)
    expect(e.direction).to eq(:falling)
    # The kick's frequency is 60 + 190 exp(-30 t)
    [0.01, 0.03, 0.1].each do |t|
      expect(e.at(t)).to be_within(0.03 * (60 + 190 * Math.exp(-30 * t))).of(60 + 190 * Math.exp(-30 * t))
    end
    expect(e.to).to be_within(3).of(61)
    expect(e.half_time.to_f).to be_within(0.006).of(Math.log(190 / 50.0) / 30) # 110 Hz, half the cents from ~198 to 61 Hz
    expect(e.to_s).to match(/pitch envelope falls from \d+ Hz to 6\d Hz/)
  end

  it 'follows a kick under its own click' do
    expect(pe.of(SyntheticSounds.kick(click: true)).at(0.03)).to be_within(5).of(137)
  end

  it 'reads a held tone as steady and gives nil for noise' do
    e = pe.of(SyntheticSounds.tone(220, 0.5))
    expect(e.direction).to eq(:steady)
    expect(e.from).to be_within(2).of(220)
    expect(e.half_time).to be_nil
    expect(pe.of(SyntheticSounds.noise(0.5))).to be_nil
  end
end
