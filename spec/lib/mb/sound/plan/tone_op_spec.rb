# The tone op (C and Ruby mirror) against Tone#sample, bit for bit, over
# block sizes from 1 to 800, modulation, and resets (see
# spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Plan::Op::Tone) do
  let(:src) { PlanSpecHelpers::Source }

  # The C plans are bit-exact; the Ruby mirror runs the Tone's own Ruby
  # kernels, whose complex sines differ from C's by rounding.
  def plan_compare(**kw, &block)
    super(ruby_tolerance: 1e-6, **kw, &block)
  end

  # Resets at block edges (the cumulative block starts of SIZES), inside
  # blocks, close together (within a band-limited jump's 32 samples), and at
  # sample 0.
  let(:reset_points) {
    starts = PlanSpecHelpers::SIZES.each_with_object([0]) { |n, acc| acc << acc.last + n }
    (starts.values_at(1, 3, 5, 8, 12) + [0, 50, 51, 70, 900, 931, 1500, 1501, 1502, 4000, 4010, 6200]).uniq.sort
  }

  def fm(seed = 1, base = 300, depth = 80)
    src.new(seed: seed, scale: depth, offset: base) * 1
  end

  describe 'naive shapes' do
    [:sine, :complex_sine, :atriangle, :acomplex_triangle, :asquare, :acomplex_square, :aramp, :acomplex_ramp, :gauss, :parabola].each do |shape|
      it "matches #{shape} with frequency and phase modulation" do
        r = plan_compare { fm(1).tone.send(shape).at(0.8).pm(src.new(seed: 2, scale: 2) * 1) * 0.5 }
        expect(r.program.tones.map(&:kernel)).to eq([:naive])
      end
    end

    it 'matches a constant frequency (the unaccumulated phase path)' do
      plan_compare { 441.hz.sine.at(0.25) * src.new(seed: 3) }
    end

    it 'matches a frequency from a Constant (accumulated, as from a buffer)' do
      plan_compare { |c|
        f = 220.constant
        c.before_block(6) { f.constant = 330 }
        MB::Sound::Tone.new(frequency: f).at(0.5) * 1
      }
    end

    it 'matches complex phase modulation (real parts)' do
      plan_compare { 300.hz.sine.pm(src.new(seed: 2, complex: true) * 1) * 1 }
    end

    it 'matches an output range (#at with a Range) and a fixed phase offset' do
      plan_compare { fm(3).tone.sine.at(-20..-3).pm(0.7) * 1 }
    end

    it 'matches a gain input, a number, and a node' do
      plan_compare { fm(1).tone.sine.gain(src.new(seed: 5)) + fm(2).tone.complex_sine.gain(0.3).real }
    end

    it 'matches noise (random advance with its own generator state)' do
      plan_compare { fm(1).tone.sine.noise(0.3) * 1 }
    end

    it 'matches resets to the starting phase, to a number, and to a node' do
      plan_compare {
        trig = src.new(kind: :impulses, at: reset_points)
        trig2 = src.new(kind: :impulses, at: reset_points.map { |p| p + 7 }, value: 0.5)
        a = fm(1).tone.sine.reset(trig)
        b = fm(2).tone.complex_sine.reset(trig, to: 1.25).real
        c = fm(3).tone.sine.reset(trig2, to: src.new(seed: 4, scale: 3))
        a + b + c
      }
    end

    it 'matches random-phase resets (rnd)' do
      plan_compare { fm(1).tone.sine.rnd.reset(src.new(kind: :impulses, at: reset_points)) * 1 }
    end

    it 'keeps playing after its reset input ends' do
      r = plan_compare { fm(1).tone.sine.reset(src.new(kind: :impulses, at: [10, 200], ends_at: 600)) * 1 }
      # (the reset input's short last buffer shortens that block, as it does unplanned)
      expect(r.outputs[:c].last.length).to eq(PlanSpecHelpers::SIZES.last)
    end

    it 'ends when its frequency input ends' do
      plan_compare(sizes: [100, 200, 300, 300]) { MB::Sound::Tone.new(frequency: src.new(seed: 1, scale: 50, offset: 200, ends_at: 450)) * 1 }
    end
  end

  describe 'band-limited shapes' do
    [:ramp, :square, :triangle].each do |shape|
      it "matches #{shape} with frequency and phase modulation" do
        r = plan_compare { fm(1, 1000, 400).tone.send(shape).at(0.8).pm(src.new(seed: 2, scale: 0.5) * 1) * 1 }
        expect(r.program.tones.map(&:kernel)).to eq([:synth])
      end

      it "matches #{shape} with key-sync resets (band-limited steps queued across blocks)" do
        plan_compare { fm(1, 2000, 300).tone.send(shape).reset(src.new(kind: :impulses, at: reset_points)) * 1 }
      end
    end

    it 'matches width modulation (pwm) of a square, a sine, and a parabola' do
      plan_compare {
        w = src.new(seed: 3, scale: 0.3, offset: 0.5)
        fm(1, 700).tone.square.pwm(w) + fm(2, 500).tone.sine.pwm(0.3) + fm(3, 200).tone.parabola.pwm(w, dc: true)
      }
    end

    it 'matches resets of a warped shape at audio rate' do
      plan_compare {
        trig = src.new(kind: :impulses, at: (0..8000).step(37).to_a)
        fm(1, 900).tone.square.pwm(src.new(seed: 3, scale: 0.2, offset: 0.4)).reset(trig, to: 0.4) * 1
      }
    end

    it 'matches LFOs (band-limiting faded in with frequency)' do
      plan_compare { (src.new(seed: 1, scale: 30, offset: 20) * 1).tone.triangle.lfo.at(0..1) * src.new(seed: 2) }
    end

    it 'matches a tone whose first sample is a reset' do
      plan_compare(sizes: [1, 64, 3, 128]) { 1000.hz.ramp.reset(src.new(kind: :impulses, at: [0, 1, 65])) * 1 }
    end
  end

  describe 'FM stacks' do
    it 'matches a 4-operator stack of complex sines with key-sync resets and envelopes as inputs' do
      r = plan_compare {
        trig = src.new(kind: :impulses, at: reset_points)
        base = fm(1, 110, 3)
        env = ->(seed) { src.new(seed: seed, scale: 0.5, offset: 0.5) }
        c = env.(2) * (base * 2).tone.complex_sine.pm(env.(3) * (base * 2).tone.sine.reset(trig)).reset(trig)
        d = env.(4) * (base * 0.9996 - 0.22).tone.complex_sine.reset(trig)
        e = env.(5) * base.tone.complex_sine.pm(c + d).reset(trig)
        f = env.(6) * base.tone.complex_sine.pm(e).reset(trig)
        f.real * 0.125
      }
      expect(r.program.tones.length).to eq(5)
    end
  end

  it 'lists its inputs' do
    r = plan_compare(sizes: [64]) { fm(1).tone.square.pwm(0.3).reset(src.new(kind: :impulses, at: [3])).gain(0.5) * 1 }
    expect(r.program.to_s).to match(/bl_square\(freq: v\d+, width: 0.3, reset: v\d+, gain: 0.5\)/)
  end
end
