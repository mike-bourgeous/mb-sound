require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::PerceivedPitch) do
  let(:pp) { MB::Sound::Analysis::PerceivedPitch }

  it 'names the pitch of a sine and of a harmonic tone, refined to a few cents' do
    [SyntheticSounds.sine(110, 0.2), SyntheticSounds.tone(110, 0.2)].each do |x|
      p = pp.new(x)
      expect(1200 * Math.log2(p.pitch.frequency / 110)).to be_within(5).of(0)
      expect(p.candidates.first.why).to eq(:best)
      expect(p.note_label).to start_with('A2')
    end
  end

  it 'hears the fundamental of a tone missing it (subharmonic summation)' do
    t = SyntheticSounds.times(0.2)
    x = Numo::DFloat.zeros(t.length)
    (2..8).each { |k| x += Numo::NMath.sin(t * 2 * Math::PI * 200 * k) / k }
    expect(pp.new(x).pitch.frequency).to be_within(2).of(200)
  end

  it 'scouts octaves: candidates an octave up and down with their scores' do
    p = pp.new(SyntheticSounds.tone(220, 0.2))
    up = p.candidates.find { |c| c.why == :octave_up }
    down = p.candidates.find { |c| c.why == :octave_down }
    expect(up.midi).to be_within(0.2).of(p.candidates.first.midi + 12)
    expect(down.midi).to be_within(0.2).of(p.candidates.first.midi - 12)
    expect([up.score, down.score].max).to be < 1
    expect(p.to_s).to include('(octave up)', '(octave down)')
  end

  it 'has no pitch for silence' do
    expect(pp.new(Numo::DFloat.zeros(4096)).pitch).to be_nil
  end
end
