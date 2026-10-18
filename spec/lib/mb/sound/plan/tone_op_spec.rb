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

  # Resets at block edges (the cumulative block starts of the sizes
  # plan_compare uses for them: SIZES repeated past 6200), inside blocks,
  # close together (within a band-limited jump's 32 samples), and at sample
  # 0.
  let(:reset_points) {
    starts = PlanSpecHelpers.sizes_for(samples: 6201).each_with_object([0]) { |n, acc| acc << acc.last + n }
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

    it 'matches #at with a node, which becomes the gain inside the tone op' do
      r = plan_compare { fm(1).tone.saw.at(0.5).at(src.new(seed: 5)) * 1 }
      expect(r.program.to_s).to match(/gain: v\d+/)
      r = plan_compare { fm(2).tone.saw.at(0.2..0.9).gain(0.37).at(src.new(seed: 6)) * 1 }
      expect(r.program.to_s).to match(/gain: v\d+/)
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
      expect(r.outputs[:c].last.length).to eq(r.sizes.last)
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

    it 'matches warp pivots: skewed triangles (default pivot), explicit pivots, and resets' do
      plan_compare {
        w = src.new(seed: 3, scale: 0.4, offset: 0.5)
        trig = src.new(kind: :impulses, at: (0..8000).step(53).to_a)
        fm(1, 700).tone.triangle.skew(w) + fm(2, 500).tone.atriangle.skew(0.9) +
          fm(3, 300).tone.sine.pwm(0.2, pivot: 0.3) + fm(4, 400).tone.saw.pwm(w, pivot: -0.4, dc: true) +
          fm(5, 900).tone.square.pwm(0.3, pivot: 0.1).reset(trig, to: 0.2) +
          fm(6, 200).tone.triangle.skew(0.8, pivot: 0)
      }
    end

    it 'leaves a tone with a pivot node unplanned' do
      tone = 300.hz.triangle.skew(0.7, pivot: src.new(seed: 1))
      expect(tone.plan_unsupported_reason).to match(/pivot/)
      expect(300.hz.triangle.skew(0.7, pivot: 0.2).plan_unsupported_reason).to be_nil
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
      plan_compare(sizes: [1, 64, 3, 128]) { 1000.hz.saw.reset(src.new(kind: :impulses, at: [0, 1, 65])) * 1 }
    end
  end

  describe 'wavetables' do
    it 'matches a wavetable with frequency and phase modulation' do
      r = plan_compare { fm(1, 300, 80).tone.wavetable(:saw).pm(src.new(seed: 2, scale: 0.2) * 1) * 0.5 }
      expect(r.program.tones.map(&:kernel)).to eq([:wavetable])
    end

    it 'matches a moving scan, with and without scan_wrap' do
      plan_compare {
        scan = src.new(seed: 4, scale: 0.6, offset: 0.5)
        fm(1, 220).tone.wavetable(:basic, scan: scan) + fm(2, 330).tone.wavetable(:pulses, scan: scan * 1.2, scan_wrap: true) * 0.5
      }
    end

    it 'matches a fixed scan and every interpolation' do
      plan_compare {
        [:optimal, :cubic, :linear, :none, :sinc].each_with_index.map { |interp, i|
          fm(i + 1, 200 + 150 * i).tone.wavetable(:basic, scan: 0.3, interpolation: interp) * 0.2
        }.reduce(:+)
      }
    end

    it 'matches a warped wavetable (pwm with band-limited corners)' do
      plan_compare {
        w = src.new(seed: 3, scale: 0.3, offset: 0.5)
        fm(1, 700).tone.wavetable(:saw).pwm(w) + fm(2, 400).tone.wavetable(:triangle).pwm(0.3, dc: true) * 0.5
      }
    end

    it 'matches a noise wavetable' do
      plan_compare { fm(1, 300).tone.wavetable(:saw).noise(0.4) * 1 }
    end

    it 'matches key-sync resets with band-limited steps' do
      plan_compare { fm(1, 900, 300).tone.wavetable(:square).reset(src.new(kind: :impulses, at: reset_points)) * 1 }
    end

    it 'matches a KeyMap picking zones at resets and, without resets, every block (also in check mode)' do
      plan_compare(check: :raise) {
        km = MB::Sound::Wavetable::KeyMap.new(MB::Sound::C1...MB::Sound::C4 => :saw, MB::Sound::C4...MB::Sound::C5 => :square, MB::Sound::C5..MB::Sound::C8 => :triangle)
        sweep = -> (seed) { src.new(seed: seed, scale: 400, offset: 450) * 1 }
        a = sweep.(1).tone.wavetable(km).reset(src.new(kind: :impulses, at: reset_points))
        b = sweep.(2).tone.wavetable(km)
        a * 0.5 + b * 0.5
      }
    end

    it 'leaves sample-mode, complex, and clean wavetables unplanned' do
      samples = MB::Sound::Wavetable.from_samples(Numo::SFloat.new(2000).rand(-1, 1), mode: :sample, root: 440)
      tone = 300.hz.wavetable(:saw)
      expect(tone.plan_unsupported_reason).to be_nil
      expect(300.hz.wavetable(:saw).clean.reset(src.new(kind: :impulses, at: [5])).plan_unsupported_reason).to match(/clean/)
      expect(300.hz.complex_saw.pm(0.1).plan_unsupported_reason).to match(/complex shape/)
      expect(300.hz.wavetable(samples).plan_unsupported_reason).to match(/sample-mode/)
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

  describe 'fast precision (Plan.precision = :fast, the default)' do
    around do |ex|
      old = MB::Sound::Plan.precision
      MB::Sound::Plan.precision = :fast
      ex.run
    ensure
      MB::Sound::Plan.precision = old
    end

    it 'stays within its stated tolerance for sines with FM, PM, ranges, and resets' do
      tol = MB::Sound::Plan::Op::Tone::FAST_TOLERANCE
      r = plan_compare(tolerance: tol) {
        trig = src.new(kind: :impulses, at: reset_points)
        a = fm(1).tone.sine.pm(src.new(seed: 2, scale: 40) * 1).reset(trig)
        b = fm(2, 3000, 2000).tone.sine.at(0.5).pm(src.new(seed: 3, complex: true, scale: 3) * 1).reset(trig, to: 1.0)
        a + b + 440.hz.sine.at(-3..1)
      }
      expect(r.program.tones.map(&:fast)).to all(eq(true))
      expect(r.program).not_to be_exact
      expect(r.program.to_s).to include('fast_sine')
    end

    it 'gives exactly the same samples in C and the Ruby mirror (Plan::VecSine)' do
      r = plan_compare { fm(1).tone.sine.at(0.7).pm(src.new(seed: 2, scale: 5) * 1) + 1234.5.hz.sine.pm(2.5) }
      c = r.outputs[:c].compact
      ruby = r.outputs[:ruby].compact
      expect(c.zip(ruby).map { |x, y| x.to_binary == y.to_binary }).to all(eq(true))
    end

    it 'keeps complex sines, noise, and other shapes exact' do
      r = plan_compare(ruby_tolerance: 1e-6) { fm(1).tone.saw * 1 + fm(2).tone.atriangle + fm(3).tone.complex_sine.real + fm(1).tone.sine.noise(0.2) }
      expect(r.program).to be_exact
    end

    it 'keeps sines exact with Plan.precision :exact' do
      MB::Sound::Plan.precision = :exact
      r = plan_compare { fm(1).tone.sine.pm(src.new(seed: 2, scale: 3) * 1) * 1 }
      expect(r.program).to be_exact
    end

    it 'is within 6e-7 of libm\'s sine (-124 dB) for every phase' do
      x = Numo::DFloat.new(100_001).seq(-3, 6e-5)
      got = MB::Sound::Plan::VecSine.shape_ruby(x, 0, 1, 0)
      worst = (Numo::DFloat.cast(got) - Numo::NMath.sin(x * (2 * Math::PI))).abs.max
      expect(worst).to be < 6e-7
    end
  end

  it 'lists its inputs' do
    r = plan_compare(sizes: [64]) { fm(1).tone.square.pwm(0.3).reset(src.new(kind: :impulses, at: [3])).gain(0.5) * 1 }
    expect(r.program.to_s).to match(/bl_square\(freq: v\d+, width: 0.3, reset: v\d+, gain: 0.5\)/)
  end
end
