# Each arithmetic node's ops (C and Ruby mirror) against the node's own
# #sample, bit for bit, over block sizes from 1 to 800 (see
# spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Plan, 'arithmetic ops') do
  let(:src) { PlanSpecHelpers::Source }

  describe 'Multiplier' do
    it 'matches a product of boundary inputs and a constant' do
      r = plan_compare { 0.37 * src.new(seed: 1) * src.new(seed: 2) * src.new(seed: 3, kind: :steps) }
      expect(plan_op_names(r)).to include(:Mul)
      expect(r.regions.first.members.length).to eq(4) # three Multipliers and a Constant
    end

    it 'matches with a complex input (real promoted)' do
      r = plan_compare { src.new(seed: 1) * src.new(seed: 2, complex: true) * 3 }
      expect(r.program.output_type).to eq(:complex)
    end

    it 'matches with a complex constant' do
      plan_compare { src.new(seed: 4) * (Complex(0.5, -0.25) * src.new(seed: 2)) }
    end

    it 'matches a product of two complex inputs' do
      plan_compare { src.new(seed: 1, complex: true) * src.new(seed: 2, complex: true) * src.new(seed: 3) }
    end

    it 'matches a Multiplier whose buffer was promoted to complex by an earlier input' do
      plan_compare { |c|
        m = MB::Sound::GraphNode::Multiplier.new([src.new(seed: 1)], sample_rate: 48000)
        m.sample(4)
        m.send(:promote_buffer, complex: true)
        m * src.new(seed: 5)
      }
    end

    it 'follows a change of the constant (a rebuild)' do
      r = plan_compare(fallbacks: true) { |c|
        m = 2 * src.new(seed: 1)
        c.before_block(5) { m.constant = 3.5 }
        m * src.new(seed: 2)
      }
      expect(r.regions.first.program.ops.map(&:to_s).join).to include('3.5')
    end

    it 'follows an input added while playing' do
      plan_compare(fallbacks: true) { |c|
        m = src.new(seed: 1) * src.new(seed: 2)
        c.before_block(4) { m.add(src.new(seed: 6, kind: :steps)) }
        m * 0.5
      }
    end
  end

  describe 'Mixer' do
    it 'matches gains of 1, -1, and others with a constant' do
      r = plan_compare {
        MB::Sound::GraphNode::Mixer.new([[src.new(seed: 1), 1], [src.new(seed: 2), -1], [src.new(seed: 3), 0.3], 0.25], sample_rate: 48000) * 1.5
      }
      expect(plan_op_names(r)).to include(:Add, :Mul)
    end

    it 'matches with complex inputs and a complex gain' do
      plan_compare {
        MB::Sound::GraphNode::Mixer.new([[src.new(seed: 1), 1], [src.new(seed: 2, complex: true), Complex(0.5, 0.5)], [src.new(seed: 3), 2]], sample_rate: 48000) * 1
      }
    end

    it 'matches a complex input with a real gain and a complex constant' do
      plan_compare {
        (src.new(seed: 1, complex: true) * 0.75 + Complex(0.1, -0.2)) * src.new(seed: 2)
      }
    end

    it 'matches subtraction' do
      plan_compare { (src.new(seed: 1) - src.new(seed: 2)) * 2 }
    end

    it 'matches a mixer with no inputs (just the constant)' do
      plan_compare { src.new(seed: 1) * MB::Sound::GraphNode::Mixer.new([], sample_rate: 48000).tap { |m| m.constant = 0.375 } }
    end
  end

  describe 'Constant' do
    it 'matches a steady constant (a filled param)' do
      r = plan_compare { 0.5.constant * src.new(seed: 1) + 0.25.constant }
      expect(plan_op_names(r)).to include(:Param)
    end

    it 'matches value changes between blocks, smoothed and not' do
      plan_compare { |c|
        a = 1.constant
        b = 2.constant(smoothing: false)
        c.before_block(2) { a.constant = 3 }
        c.before_block(3) { b.constant = -1 }
        c.before_block(7) { a.constant = 0.5; b.constant = 0.25 }
        (a * src.new(seed: 1)) + b
      }
    end

    it 'matches changes inside a block (timed and indexed)' do
      plan_compare { |c|
        a = 1.constant
        c.before_block(3) { a.indexed_change(0.5, 1); a.indexed_change(2, 2) }
        c.before_block(9) { a.timed_change(-1, 0.0001) }
        a * src.new(seed: 2)
      }
    end

    it 'matches a complex constant' do
      plan_compare { Complex(0.5, 0.5).constant * src.new(seed: 2) * src.new(seed: 3) }
    end

    it 'recompiles when a constant turns complex' do
      r = plan_compare(fallbacks: true) { |c|
        a = 1.constant
        c.before_block(4) { a.constant = Complex(0, 1) }
        a * src.new(seed: 2) * src.new(seed: 3)
      }
      expect(r.program.output_type).to eq(:complex)
    end
  end

  describe 'ComplexNode' do
    it 'matches real and imaginary parts of a complex input' do
      r = plan_compare { (src.new(seed: 1, complex: true) * 2).real + (src.new(seed: 2, complex: true) * 3).imag }
      expect(plan_op_names(r)).to include(:Part)
    end

    it 'matches parts of a real input' do
      plan_compare { (src.new(seed: 1) * 2).real + (src.new(seed: 2) * 3).imag }
    end
  end

  describe 'GraphNode arithmetic procs' do
    it 'matches division by a number and by a node' do
      r = plan_compare { ((src.new(seed: 1) * 2) / 20 + (src.new(seed: 3) * 1) / (src.new(seed: 2, offset: 3) * 1)) * 1 }
      expect(plan_op_names(r)).to include(:Div)
    end

    it 'matches 10 ** (x / 20) (dB to gain)' do
      r = plan_compare { 10 ** (src.new(seed: 1, scale: 20, offset: -20) * 1 / 20) * src.new(seed: 4) }
      expect(plan_op_names(r)).to include(:Pow)
    end

    it 'matches note numbers to frequencies (Tuning#freq), following tuning changes' do
      r = plan_compare { |c|
        c.before_block(5) { MB::Sound.tuning(b4: 480) }
        c.before_block(9) { MB::Sound.tuning.reset }
        MB::Sound.tuning.freq(src.new(seed: 1, scale: 12, offset: 60) * 1).tone.sine * MB::Sound::C4.freq.tone.ramp
      }
      expect(plan_op_names(r)).to include(:NoteFreq)
    ensure
      MB::Sound.tuning.reset
    end

    describe 'vectorized 2^x (Plan.precision :fast, the default)' do
      around do |ex|
        old = MB::Sound::Plan.precision
        MB::Sound::Plan.precision = :fast
        ex.run
      ensure
        MB::Sound::Plan.precision = old
        MB::Sound.tuning.reset
      end

      let(:vx) { MB::Sound::Plan::VecExp2 }

      it 'gives exactly the same samples in C and the Ruby mirror (Plan::VecExp2) for powers and note frequencies' do
        r = plan_compare { |c|
          c.before_block(5) { MB::Sound.tuning(b4: 480) }
          f = MB::Sound.tuning.freq(src.new(seed: 1, scale: 30, offset: 60) * 1)
          g = 10 ** (src.new(seed: 3, scale: 40, offset: -30) * 1 / 20)
          h = 2 ** (src.new(seed: 5, scale: 3) * 1)
          f.tone.sine * g + h * 0.1
        }
        ops = r.program.ops.select { |op| op.is_a?(MB::Sound::Plan::Op::Pow) || op.is_a?(MB::Sound::Plan::Op::NoteFreq) }
        expect(ops.length).to eq(3)
        expect(ops.map(&:fast)).to all(eq(true))
        expect(r.program).not_to be_exact
        c = r.outputs[:c].compact
        ruby = r.outputs[:ruby].compact
        expect(c.zip(ruby).map { |x, y| x.to_binary == y.to_binary }).to all(eq(true))
      end

      it 'keeps powers of a node base and Plan.precision :exact on libm' do
        r = plan_compare { (src.new(seed: 1, offset: 2) * 1) ** (src.new(seed: 2) * 1) * 1 }
        expect(r.program).to be_exact

        MB::Sound::Plan.precision = :exact
        r = plan_compare { 10 ** (src.new(seed: 1) * 1) * MB::Sound.tuning.freq(src.new(seed: 2, scale: 12, offset: 60) * 1) }
        expect(r.program).to be_exact
      end

      it 'matches libm within a float step for every note (and bend step) and 10^x' do
        n = Numo::SFloat.new(182_858).seq(0, 0.0007)
        got = vx.note_freq(n, 69, 440)
        ref = MB::FastSound.number_to_freq(n.dup.inplace!, 69, 440).not_inplace!
        rel = ((Numo::DFloat.cast(got) - ref) / ref).abs.max
        expect(rel).to be <= 1.2e-7

        x = Numo::SFloat.new(200_000).seq(-3, 0.00003)
        got = vx.pow(Numo::SFloat.new(x.length).fill(10), x)
        ref = (Numo::SFloat.new(x.length).fill(10).inplace ** x).not_inplace!
        rel = ((Numo::DFloat.cast(got) - ref) / ref).abs.max
        expect(rel).to be <= 1.2e-7
      end

      it 'gives libm\'s results for bases and exponents outside the fast path, and at the limits' do
        a = Numo::SFloat[-2, 0, 1, 1, 2, Float::INFINITY, Float::NAN, 2, 2, 2, 10, 10, 0.5]
        b = Numo::SFloat[3, 2, Float::INFINITY, Float::NAN, Float::NAN, 0, 1, Float::INFINITY, -Float::INFINITY, 1000, -60, 39, 200]
        got = vx.pow(a, b)
        ref = (a.dup.inplace ** b).not_inplace!
        expect(got.to_a.zip(ref.to_a).map { |g, r| g.equal?(r) || g == r || (g.nan? && r.nan?) }).to all(eq(true))

        # Note numbers whose 2^x is beyond the polynomial's limit, and NaN
        n = Numo::SFloat[69 + 12 * 250, 69 - 12 * 250, Float::NAN, Float::INFINITY, -Float::INFINITY, 69]
        got = vx.note_freq(n, 69, 440)
        ref = MB::FastSound.number_to_freq(n.dup.inplace!, 69, 440).not_inplace!
        expect(got.to_a.zip(ref.to_a).map { |g, r| g == r || (g.nan? && r.nan?) }).to all(eq(true))

        # Results down through float's subnormals to 0 (2^-160..2^40) through
        # the plan
        r = plan_compare(sizes: [13, 64]) { 2 ** (src.new(seed: 1, scale: 100, offset: -60) * 1) * 1 }
        expect(r.program).not_to be_exact
      end
    end

    it 'leaves other procs unfused' do
      g = (src.new(seed: 1) * 2).proc { |v| v * 2 } * 3
      expect(MB::Sound::Plan.explain(g)).to include('a Ruby block')
    end
  end

  describe 'Shaper' do
    [[:softclip, [0.3, 0.9]], [:clip, [-0.4, 0.6]], [:abs, []], [:quantize, [0.125]]].each do |mode, args|
      it "matches #{mode}, antialiased and plain" do
        r = plan_compare {
          x = src.new(seed: 1, scale: 1.5) * src.new(seed: 2)
          x.send(mode, *args) + x.send(:"a#{mode}", *args) * 0.5
        }
        # (aquantize is GraphNode::Quantize, which has no ops yet)
        expect(plan_op_names(r).count(:Shape)).to eq(mode == :quantize ? 1 : 2)
      end
    end

    it 'matches a one-sided clip and a softclip of a planned tone' do
      plan_compare { (220.hz.ramp * 1.5).clip(nil, 0.5) + (330.hz.sine.at(2) * src.new(seed: 3)).softclip }
    end

    it 'leaves a shaper of complex input unfused' do
      text = MB::Sound::Plan.explain((src.new(seed: 1, complex: true) * 2).softclip * 3)
      expect(text).to include('complex input')
    end
  end

  describe 'ends and short reads' do
    it 'ends when a required input ends, after a short block' do
      r = plan_compare(sizes: [100, 128, 128, 128]) { src.new(seed: 1, ends_at: 300) * src.new(seed: 2) * 2 }
      expect(r.outputs[:c].map { |o| o&.length }).to eq([100, 128, 72, nil])
    end
  end
end

RSpec.describe(MB::Sound::Plan::Fold) do
  let(:src) { PlanSpecHelpers::Source }

  around do |ex|
    old = MB::Sound::Plan.fold_warnings
    MB::Sound::Plan.fold_warnings = false
    ex.run
  ensure
    MB::Sound::Plan.fold_warnings = old
  end

  def folds(r)
    r.regions.flat_map { |g| g.folds || [] }
  end

  it 'folds 0 * x to 0 and propagates through later products, matching the unfused graph' do
    r = plan_compare(check: :raise) { (src.new(seed: 1) * 1 * 0) * 3 * src.new(seed: 2) + src.new(seed: 3) * 1 }
    expect(folds(r).length).to be >= 2
    expect(folds(r).map(&:primary)).to include(true, false)
    expect(r.program.to_s).to include('folded: 0 *')
  end

  it 'keeps running the folded factor\'s ops, so their nodes\' state advances as unfused (checked per block)' do
    r = plan_compare(check: :raise) {
      tone = 123.hz.ramp.pm(src.new(seed: 1) * 0.5)
      tone * 0 + 77.hz.sine * 0.5
    }
    expect(folds(r).length).to eq(1)
    expect(r.program.tones.length).to eq(2)
  end

  it 'keeps Tee branches of the folded factor in step with their other readers' do
    s = src.new(seed: 4)
    x = s * 2
    g = x * 0 + (x * 0.5).proc { |v| v } # the proc reads x's other branch outside the region
    MB::Sound::Plan.install(g)
    expect { 300.times { |i| g.sample([64, 128, 7][i % 3]) } }.not_to raise_error
  end

  it 'leaves a Constant node\'s live value of 0 unfolded (0 * node makes one)' do
    r = plan_compare { 0 * (src.new(seed: 1) * 1) + 1 }
    expect(folds(r)).to be_empty
  end

  it 'gives 0 where the unfused graph would give NaN for a non-finite factor (a patch bug, which check mode reports)' do
    old_check = MB::Sound::Plan.check
    MB::Sound::Plan.check = nil
    inf = 0.constant.proc { |v| Numo::SFloat.new(v.length).fill(Float::INFINITY) }
    g = inf * 1 * 0 + 1.constant * 1
    MB::Sound::Plan.install(g)
    expect(g.sample(16).to_a).to all(eq(1.0))

    MB::Sound::Plan.check = :raise
    inf2 = 0.constant.proc { |v| Numo::SFloat.new(v.length).fill(Float::INFINITY) }
    g2 = inf2 * 1 * 0 + 1.constant * 1
    MB::Sound::Plan.install(g2)
    expect { g2.sample(16) }.to raise_error(MB::Sound::Plan::CheckFailed)
  ensure
    MB::Sound::Plan.check = old_check
  end

  it 'lists folds in Plan.explain and warns once per kind of node' do
    MB::Sound::Plan.fold_warnings = true
    MB::Sound::Plan::Fold.instance_variable_set(:@warned, nil)
    g = src.new(seed: 1) * 1 * 0 + src.new(seed: 2) * 1 * 0
    text = nil
    expect { text = MB::Sound::Plan.explain(g) }.to output(/folded 0 \* x to 0/).to_stderr
    expect(text).to include('Folded 0 * x to 0').and include('x still computed')
    expect { MB::Sound::Plan.install(g); g.sample(10) }.not_to output.to_stderr
    g2 = src.new(seed: 3) * 1 * 0 + 1
    expect { MB::Sound::Plan.install(g2); g2.sample(10) }.not_to output.to_stderr
  end
end
