require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::PitchContour) do
  let(:pc) { MB::Sound::Analysis::PitchContour }

  it 'finds a vibrato of known rate and depth' do
    c = pc.new(SyntheticSounds.tone(220, 2, vibrato: [5.5, 18]))
    expect(c.median.frequency).to be_within(1).of(220)
    expect(c.voiced).to be > 0.9
    expect(c.vibrato.rate.frequency).to be_within(0.15).of(5.5)
    expect(c.vibrato.depth).to be_a(MB::Sound::Interval)
    expect(c.vibrato.depth.to_cents).to be_within(2).of(18)
    expect(c.to_s).to include('A3', 'vibrato 5.5 Hz ±1')
    expect(c.vibrato.to_h[:rate_hz]).to be_within(0.15).of(5.5)
  end

  it 'reads a steady tone as steady, within a few cents' do
    c = pc.new(SyntheticSounds.tone(220 * 2**(10 / 1200.0), 1))
    expect(c.vibrato).to be_nil
    expect(c.sweep).to be_nil
    expect(1200 * Math.log2(c.median.frequency / 220)).to be_within(2).of(10)
    expect(c.note_label).to eq('A3 +10 cents')
    ok = c.cents.to_a.reject(&:nan?)
    expect(ok.map(&:abs).max).to be < 3
  end

  it 'reads a falling kick as a sweep' do
    c = pc.new(SyntheticSounds.kick)
    expect(c.sweep).not_to be_nil
    expect(c.sweep.cents).to be < -300
    expect(c.sweep.to.frequency).to be_within(5).of(61)
    expect(c.to_s).to include('pitch falls from')
  end

  it 'has no pitch for silence or noise' do
    c = pc.new(Numo::DFloat.zeros(24000))
    expect(c.median).to be_nil
    expect(c.voiced).to eq(0)
    expect(c.to_s).to eq('no pitch (no voiced frames)')
    expect(pc.new(SyntheticSounds.noise(0.5)).voiced).to be < 0.2
  end

  it 'gives frame times at window centers every 10 ms' do
    c = pc.new(SyntheticSounds.tone(220, 0.5))
    expect(c.times[1] - c.times[0]).to be_within(1e-12).of(0.01)
    expect(c.times[0]).to be_within(1e-12).of(0.02)
    expect([c.hz.length, c.cents.length, c.aperiodicity.length].uniq).to eq([c.times.length])
  end
end
