# Phases are in cycles everywhere (2026-10-10): plain numbers and nodes
# count cycles in every phase input, and MB::Sound::Phase states a unit
# explicitly (Numeric#cycles, Numeric#radians, Phase.degrees,
# GraphNode#cycles, GraphNode#radians).
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
      expect(MB::Sound::Phase.to_radians(0.5.cycles)).to eq(Math::PI)
      expect(MB::Sound::Phase.to_radians(0.5)).to eq(Math::PI)
      expect(MB::Sound::Phase.to_radians(nil)).to be_nil
      expect(MB::Sound::Phase.cycles(0.5.cycles)).to eq(0.5)
      expect(MB::Sound::Phase.cycles(0.5)).to eq(0.5)
      expect(MB::Sound::Phase.cycles(nil)).to be_nil
      expect(MB::Sound::Phase.degrees(90)).to eq(0.25.cycles)
    end

    it 'makes radians phases that keep their radians exactly' do
      ph = 1.5.radians
      expect(ph).to be_radians
      expect(ph.to_radians).to eq(1.5)
      expect(ph.to_cycles).to eq(1.5 / (2 * Math::PI))
      expect(MB::Sound::Phase.radians(1.5)).to eq(ph)
      expect(1.5.rad).to eq(ph)
      expect(1.radian.to_radians).to eq(1)
      expect(ph.to_s).to eq('1.5 radians')
      expect(0.25.cycles).not_to be_radians
    end

    it 'compares, adds, and scales' do
      expect(0.25.cycles + 0.5.cycles).to eq(0.75.cycles)
      expect(0.75.cycles - 0.5.cycles).to eq(0.25.cycles)
      expect(0.25.cycles * 2).to eq(0.5.cycles)
      expect(2 * 0.25.cycles).to eq(0.5.cycles)
      expect(0.5.cycles / 2).to eq(0.25.cycles)
      expect(-0.25.cycles).to eq(MB::Sound::Phase.new(-0.25))
      expect(0.25.cycles).to be < 0.5.cycles
      expect(Math::PI.radians).to be > 0.25.cycles
      expect(0.25.cycles.to_s).to eq('0.25 cycles')
      expect { 0.25.cycles + 1 }.to raise_error(ArgumentError, /phase/)
      expect { MB::Sound::Phase.new('x') }.to raise_error(ArgumentError)
      expect { MB::Sound::Phase.new(1, unit: :grads) }.to raise_error(ArgumentError, /unit/)
    end

    it 'marks nodes as cycles or radians' do
      lfo = 2.hz.lfo
      ph = lfo.cycles
      expect(ph).to be_node
      expect(ph.to_cycles).to equal(lfo)
      expect(ph.to_radians).to equal(ph.to_radians) # one multiplier
      expect { ph + 0.5.cycles }.to raise_error(ArgumentError, /node/)

      rad = lfo.radians
      expect(rad).to be_node
      expect(rad).to be_radians
      expect(rad.to_radians).to equal(lfo)
      expect(rad.to_cycles).to respond_to(:sample)
    end
  end

  describe 'in oscillator methods' do
    it 'starts tones at a phase in cycles (#with_phase)' do
      expect(take(440.hz.with_phase(0.25))).to eq(take(440.hz.sine.with_phase_cycles(0.25)))
      expect(take(440.hz.with_phase(0.25.cycles))).to eq(take(440.hz.sine.with_phase(0.25)))
      expect(take(440.hz.with_phase((Math::PI / 2).radians))).to eq(take(440.hz.sine.with_phase(0.25)))
      expect(take(440.hz.with_phase(MB::Sound::Phase.degrees(90)))).to eq(take(440.hz.sine.with_phase(0.25)))
      expect(440.hz.sine.with_phase(0.25).sample(1)[0]).to be_within(1e-7).of(1)
      expect { 440.hz.sine.with_phase(2.hz.lfo) }.to raise_error(ArgumentError, /cycles/)
    end

    it 'takes PM depths in cycles (#pm index, #pm_cycles, node.radians)' do
      ref = take(110.hz.sine.pm(330.hz.sine, 0.4))
      expect(take(110.hz.sine.pm(330.hz.sine, 0.4.cycles))).to eq(ref)
      expect(take(110.hz.sine.pm_cycles(330.hz.sine, 0.4))).to eq(ref)
      expect(take(110.hz.pm_cyc(330.hz.sine, 0.4))).to eq(ref)
      expect(take(110.hz.sine.pm(330.hz.sine, (Math::PI * 0.8).radians))).to all_be_within(1e-6).of_array(ref)

      # Without an index the modulator's own level is in cycles
      ref2 = take(110.hz.sine.pm(330.hz.sine.at(0.3)))
      out2 = take(110.hz.sine.pm(330.hz.sine.at(2 * Math::PI * 0.3).radians))
      expect((out2 - ref2).abs.max).to be < 1e-6
      out3 = take(110.hz.sine.pm(330.hz.sine.at(0.3).cycles))
      expect(out3).to eq(ref2)

      # A fixed offset: a quarter cycle turns a sine into a cosine
      cos = take(100.hz.sine.pm(0.25.cycles), 480)
      expect(cos[0]).to be_within(1e-6).of(1)
    end

    it 'takes reset targets, feedback amounts, unison phases, and resonator phases in cycles' do
      trig = 0.constant # never fires; checks the setting
      expect(55.hz.saw.reset(trig, to: 0.5.cycles).reset_to).to eq(0.5)
      expect(55.hz.saw.reset(trig, to: 0.5).reset_to).to eq(0.5)
      expect(55.hz.saw.reset(trig, to: Math::PI.radians).reset_to).to eq(0.5)
      expect(110.hz.sine.fm_feedback(0.3.cycles).fm_feedback_amount).to eq(0.3)
      expect(110.hz.sine.fm_feedback(0.3).fm_feedback_amount).to eq(0.3)
      expect(110.hz.sine.fm_feedback_cycles(0.3).fm_feedback_amount).to eq(0.3)

      u1 = take(MB::Sound.with_seed(1) { 110.hz.unison(3, phase: 0.25) { |p| p.sine } })
      u2 = take(MB::Sound.with_seed(1) { 110.hz.unison(3, phase: (Math::PI / 2).radians) { |p| p.sine } })
      expect(u1).to eq(u2)

      imp = -> { MB::Sound.impulse(0.1) }
      expect(take(imp.call.ping(100, phase: 0.25), 480)).to eq(take(imp.call.ping(100, phase: (Math::PI / 2).radians), 480))
      expect(imp.call.ping(100, phase: 0.25).phase).to eq(0.25)
    end

    it 'takes harmonic phases in cycles (Wavetable.from_harmonics, Pitch#harmonics)' do
      w = MB::Sound::Wavetable
      a = w.from_harmonics([1, 0.5], [0.25, 0.5], size: 64)
      b = w.from_harmonics([1, 0.5], [(Math::PI / 2).radians, Math::PI.radians], size: 64)
      expect(a.frames).to eq(b.frames)
      expect(a.frames[0, 0]).to be_within(1e-6).of(1) # cosine plus a sine starting at 0

      h1 = take(110.hz.harmonics([1, 0.5], phases: [0.25, 0]))
      h2 = take(110.hz.harmonics([1, 0.5], phases: [(Math::PI / 2).radians, 0]))
      expect(h1).to eq(h2)
    end

    it 'reads Tone.value_at in cycles' do
      expect(MB::Sound::Tone.value_at(:sine, 0.25)).to be_within(1e-12).of(1)
      expect(MB::Sound::Tone.value_at(:ramp, 0.25)).to be_within(1e-12).of(0.5)
      expect(MB::Sound::Tone.value_at(:sine, 1.5.radians)).to be_within(1e-12).of(Math.sin(1.5))
    end
  end
end
