# Phases in cycles (MB::Sound::Phase, Numeric#cycles, GraphNode#cycles):
# methods taking radians also take Phases, so live code needs no Math::PI.
RSpec.describe(MB::Sound::Phase) do
  def take(node, n = 4800)
    node.sample(n).dup
  end

  describe 'values' do
    it 'converts between cycles, radians, and degrees' do
      expect(0.25.cycles.to_cycles).to eq(0.25)
      expect(0.25.cycles.to_radians).to eq(Math::PI / 2)
      expect(0.25.cyc.to_degrees).to eq(90)
      expect(1.cycle.to_radians).to eq(2 * Math::PI)
      expect(MB::Sound::Phase.radians(0.5.cycles)).to eq(Math::PI)
      expect(MB::Sound::Phase.radians(1.2)).to eq(1.2)
      expect(MB::Sound::Phase.radians(nil)).to be_nil
      expect(MB::Sound::Phase.cycles(0.5.cycles)).to eq(0.5)
      expect(MB::Sound::Phase.cycles(0.5)).to eq(0.5)
    end

    it 'compares, adds, and scales' do
      expect(0.25.cycles + 0.5.cycles).to eq(0.75.cycles)
      expect(0.75.cycles - 0.5.cycles).to eq(0.25.cycles)
      expect(0.25.cycles * 2).to eq(0.5.cycles)
      expect(2 * 0.25.cycles).to eq(0.5.cycles)
      expect(0.5.cycles / 2).to eq(0.25.cycles)
      expect(-0.25.cycles).to eq(MB::Sound::Phase.new(-0.25))
      expect(0.25.cycles).to be < 0.5.cycles
      expect(0.25.cycles.to_s).to eq('0.25 cycles')
      expect { 0.25.cycles + 1 }.to raise_error(ArgumentError, /phase/)
      expect { MB::Sound::Phase.new('x') }.to raise_error(ArgumentError)
    end

    it 'marks nodes as cycles' do
      lfo = 2.hz.lfo
      ph = lfo.cycles
      expect(ph).to be_node
      expect(ph.to_cycles).to equal(lfo)
      expect(ph.to_radians).to equal(ph.to_radians) # one multiplier
      expect { ph + 0.5.cycles }.to raise_error(ArgumentError, /node/)
    end
  end

  describe 'in oscillator methods' do
    it 'starts tones at a phase in cycles (#with_phase)' do
      expect(take(440.hz.with_phase(0.25.cycles))).to eq(take(440.hz.sine.with_phase_cycles(0.25)))
      expect(take(440.hz.with_phase(0.25.cycles))).to eq(take(440.hz.sine.with_phase(Math::PI / 2)))
      expect(take(440.hz.sine.with_phase_cycles(0.25.cycles))).to eq(take(440.hz.sine.with_phase_cycles(0.25)))
    end

    it 'takes PM depths in cycles (#pm index, #pm_cycles, node.cycles)' do
      ref = take(110.hz.sine.pm(330.hz.sine, Math::PI * 0.8))
      expect(take(110.hz.sine.pm(330.hz.sine, 0.4.cycles))).to eq(ref)
      expect(take(110.hz.sine.pm_cycles(330.hz.sine, 0.4))).to eq(ref)
      expect(take(110.hz.pm_cyc(330.hz.sine, 0.4))).to eq(ref)

      # Without an index the modulator's own level is in cycles
      ref2 = take(110.hz.sine.pm(330.hz.sine.at(2 * Math::PI * 0.3)))
      out2 = take(110.hz.sine.pm_cycles(330.hz.sine.at(0.3)))
      expect((out2 - ref2).abs.max).to be < 1e-6
      out3 = take(110.hz.sine.pm(330.hz.sine.at(0.3).cycles))
      expect((out3 - ref2).abs.max).to be < 1e-6

      # A fixed offset: a quarter cycle turns a sine into a cosine
      cos = take(100.hz.sine.pm(0.25.cycles), 480)
      expect(cos[0]).to be_within(1e-6).of(1)
    end

    it 'takes reset targets, feedback amounts, unison phases, and resonator phases in cycles' do
      trig = 0.constant # never fires; checks the setting
      expect(55.hz.saw.reset(trig, to: 0.5.cycles).reset_to).to eq(Math::PI)
      expect(110.hz.sine.fm_feedback(0.3.cycles).fm_feedback_amount).to be_within(1e-12).of(0.3 * 2 * Math::PI)
      expect(110.hz.sine.fm_feedback_cycles(0.3.cycles).fm_feedback_amount).to be_within(1e-12).of(0.3 * 2 * Math::PI)

      u1 = take(MB::Sound.with_seed(1) { 110.hz.unison(3, phase: 0.25.cycles) { |p| p.sine } })
      u2 = take(MB::Sound.with_seed(1) { 110.hz.unison(3, phase: Math::PI / 2) { |p| p.sine } })
      expect(u1).to eq(u2)

      imp = -> { MB::Sound.impulse(0.1) }
      expect(take(imp.call.ping(100, phase: 0.25.cycles), 480)).to eq(take(imp.call.ping(100, phase: Math::PI / 2), 480))
    end
  end
end
