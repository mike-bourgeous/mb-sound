RSpec.describe(MB::Sound::GraphNode::ChannelMixer, :aggregate_failures) do
  describe MB::Sound::GraphNode::ChannelMixer::Matrix do
    let(:identity3) { Matrix[[1, 0, 0], [0, 1, 0], [0, 0, 1]] }
    let(:matrix21) { Matrix[[0.5, 0.5]] }
    let(:matrix14) { Matrix[[1], [0.5], [-0.5], [-1]] }

    it 'returns inputs unmodified with an identity matrix' do
      mat = described_class.new([1.constant, -2.constant, 3.constant], matrix: identity3)
      expect(mat.outputs.map { |c| c.sample(1) }).to eq([Numo::SFloat[1], Numo::SFloat[-2], Numo::SFloat[3]])
    end

    it 'downmixes and upmixes' do
      expect(described_class.new([1.constant, -2.constant], matrix: matrix21).outputs.map { |c| c.sample(1) }).to eq([Numo::SFloat[-0.5]])
      expect(described_class.new(-2.constant, matrix: matrix14).outputs.map { |c| c.sample(1) }).to eq(
        [Numo::SFloat[-2], Numo::SFloat[-1], Numo::SFloat[1], Numo::SFloat[2]]
      )
    end

    it 'accepts Arrays, 2D NArrays, and bundles of inputs' do
      ins = MB::Sound.stereo(1.constant, 2.constant)
      [[[1, 1]], Numo::DFloat[[1, 1]], MB::Sound::ProcessingMatrix.new(Matrix[[1, 1]])].each do |m|
        expect(described_class.new(ins, matrix: m).outputs[0].sample(2).to_a).to eq([3, 3])
      end
    end

    it 'raises an error if the matrix does not have one column per input' do
      expect { described_class.new([1.constant], matrix: matrix21) }.to raise_error(ArgumentError, /column per input/)
    end

    it 'reads node gains every sample' do
      gain = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 1, 2, 3]])
      mat = described_class.new([1.constant, 10.constant], matrix: [[gain, 1]])
      expect(mat.params.keys).to eq([:m1_1])
      expect(mat.outputs[0].sample(4).to_a).to eq([10, 11, 12, 13])
      expect(mat.gains[0][0].to_a).to eq([0, 1, 2, 3])
    end

    it 'ends when an input or gain node ends' do
      short = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3]])
      mat = described_class.new([short, 1.constant], matrix: [[1, 1]])
      expect(mat.outputs[0].sample(5).to_a).to eq([2, 3, 4])
      expect(mat.outputs[0].sample(5)).to eq(nil)
    end

    it 'mixes every output from the same input samples' do
      lfo = 3.hz.lfo
      mat = described_class.new([lfo], matrix: [[1], [-1]])
      a, b = mat.outputs.map { |o| o.sample(800) }
      expect(a).to eq(-b)
    end

    it 'describes itself' do
      expect(described_class.new([1.constant, 2.constant], matrix: [[1, 0.5], [0.5, 1], [1, 1]]).to_s).to eq('Matrix 3x2')
    end

    context 'with complex gains' do
      let(:tone) { 1000.hz.sine }

      it 'turns real inputs into analytic signals and outputs real parts' do
        mat = described_class.new([tone], matrix: [[1i]])
        out = mat.outputs[0].multi_sample(800, 6)
        expect(out).to be_a(Numo::SFloat)

        # A 90 degree phase shift of the analytic signal: same level as the
        # input after the Hilbert filter settles
        expect(out[2400..].abs.max).to be_within(0.02).of(1)
      end

      it 'keeps complex inputs complex' do
        mat = described_class.new([1000.hz.complex_sine], matrix: [[1i]])
        out = mat.outputs[0].sample(800)
        expect(out).to be_a(Numo::SComplex)
        expect(out).to all_be_within(1e-5).of_array(1000.hz.complex_sine.sample(800) * 1i)
      end
    end

    it 'changes the sample rate of its inputs and gain nodes' do
      gain = 2.hz.lfo
      inp = 100.hz.sine
      mat = described_class.new([inp], matrix: [[gain]])
      mat.outputs[0].sample_rate = 96000
      expect(mat.sample_rate).to eq(96000)
      expect(inp.sample_rate).to eq(96000)
      expect(gain.sample_rate).to eq(96000)
    end
  end

  describe 'subclasses' do
    let(:stereo) { MB::Sound.stereo(1.constant, 0.5.constant) }

    it 'declare their parameters and options for discovery' do
      expect(MB::Sound::GraphNode::ChannelMixer::Pan.params).to eq(position: { default: 0, range: -1..1 })
      expect(MB::Sound::GraphNode::ChannelMixer::Pan.options[:law][:values]).to eq([:equal_power, :minus_4_5db, :linear])
      expect(MB::Sound::GraphNode::ChannelMixer::Pan.channels).to eq([1, 2])
      expect(MB::Sound::GraphNode::ChannelMixer::Mono.channels).to eq([:any, 1])
    end

    it 'report their parameters, options, and gains' do
      lfo = 2.hz.lfo
      pan = MB::Sound::GraphNode::ChannelMixer::Pan.new(1.constant, position: lfo, law: :linear)
      expect(pan.params[:position]).to equal(lfo)
      expect(pan.option(:law)).to eq(:linear)
      expect(pan.to_s).to start_with('Pan (law: linear, position: ')

      fixed = MB::Sound::GraphNode::ChannelMixer::Pan.new(1.constant, position: -1)
      expect(fixed.gains).to eq([[1.0], [0.0]].map { |r| r.map { |v| be_within(1e-12).of(v) } }).or eq([[Math.cos(0)], [Math.sin(0)]])
      expect(fixed.to_s).to eq('Pan (law: equal_power, position: -1)')
    end

    it 'check channel counts and parameter ranges' do
      expect { MB::Sound::GraphNode::ChannelMixer::Pan.new(stereo) }.to raise_error(ArgumentError, /1 input channel/)
      expect { MB::Sound::GraphNode::ChannelMixer::Balance.new(1.constant) }.to raise_error(ArgumentError, /2 input channels/)
      expect { MB::Sound::GraphNode::ChannelMixer::Pan.new(1.constant, position: 3) }.to raise_error(ArgumentError, /-1..1/)
      expect { MB::Sound::GraphNode::ChannelMixer::Pan.new(1.constant, law: :wide) }.to raise_error(ArgumentError, /law/)
      expect { MB::Sound::GraphNode::ChannelMixer::Pan.new(1.constant, volume: 1) }.to raise_error(ArgumentError, /Unknown settings/)
    end

    [:equal_power, :linear, :minus_4_5db].each do |law|
      it "pans a moving position in C exactly as the Numo gains and mix (#{law})" do
        make = -> { MB::Sound::GraphNode::ChannelMixer::Pan.new(330.hz.ramp, position: 3.hz.lfo.at(-1.2..1.2), law: law) }
        fast = make.call
        slow = make.call
        slow.define_singleton_method(:mix_params) { |_values, _data| nil }

        [128, 37, 800].each do |n|
          a = fast.outputs.map { |o| o.sample(n).dup }
          b = slow.outputs.map { |o| o.sample(n).dup }
          expect(a.map(&:class)).to eq(b.map(&:class))
          expect(a.map(&:to_binary)).to eq(b.map(&:to_binary))
          expect(fast.gains.map { |row| row[0].to_binary }).to eq(slow.gains.map { |row| row[0].to_binary })
        end
      end
    end

    it 'pans a moving position without allocating' do
      per_buffer = ->(&block) {
        5.times(&block)
        before = GC.stat(:total_allocated_objects)
        100.times(&block)
        (GC.stat(:total_allocated_objects) - before) / 100.0
      }

      input = 330.hz.ramp
      position = 3.hz.lfo
      sources = per_buffer.call { input.sample(128); position.sample(128) }

      l, r = MB::Sound::GraphNode::ChannelMixer::Pan.new(330.hz.ramp, position: 3.hz.lfo).outputs
      panned = per_buffer.call { l.sample(128); r.sample(128) }

      # The mixer used to add about 30 objects per buffer
      expect(panned - sources).to be < 0.5
    end

    it 'mix width, mid/side, swap, and mono as one node each' do
      first = ->(bundle) { bundle.outputs.map { |o| o.sample(2)[0] } }
      expect(first.(stereo.width(0))).to eq([0.75, 0.75])
      expect(first.(stereo.width(2))).to eq([1.25, 0.25])
      expect(first.(stereo.mid_side)).to eq([0.75, 0.25])
      expect(first.(stereo.mid_side.from_mid_side)).to eq([1, 0.5])
      expect(first.(stereo.swap)).to eq([0.5, 1])
      expect(stereo.mono.sample(2)[0]).to eq(0.75)
      expect(stereo.width(1.5).outputs.map(&:original_source).uniq.length).to eq(1)
      expect(stereo.width(1.5)[0].graph.grep(MB::Sound::GraphNode::ChannelMixer::Width).length).to eq(1)
    end

    it 'reads node parameters every sample' do
      amount = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 1, 2]])
      l, r = stereo.width(amount).outputs.map { |o| o.sample(3).to_a }
      expect(l).to eq([0.75, 1, 1.25])
      expect(r).to eq([0.75, 0.5, 0.25])
    end
  end
end
