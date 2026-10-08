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
