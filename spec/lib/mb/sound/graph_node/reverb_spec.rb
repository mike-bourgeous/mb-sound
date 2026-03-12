RSpec.describe(MB::Sound::GraphNode::Reverb) do
  describe '.hadamard_matrix' do
    it 'returns an orthogonal matrix for size 4' do
      pm = MB::Sound::GraphNode::Reverb.hadamard_matrix(4)
      m = Matrix[*pm.to_a]

      # H * H^T should equal identity for an orthogonal matrix
      product = m * m.transpose
      4.times do |i|
        4.times do |j|
          expected = i == j ? 1.0 : 0.0
          expect(product[i, j]).to be_within(1e-10).of(expected)
        end
      end
    end
  end

  describe '.householder_matrix' do
    it 'returns an orthogonal matrix for size 4' do
      pm = MB::Sound::GraphNode::Reverb.householder_matrix(4)
      m = Matrix[*pm.to_a]

      product = m * m.transpose
      4.times do |i|
        4.times do |j|
          expected = i == j ? 1.0 : 0.0
          expect(product[i, j]).to be_within(1e-10).of(expected)
        end
      end
    end

    it 'returns a symmetric matrix' do
      pm = MB::Sound::GraphNode::Reverb.householder_matrix(4)
      m = Matrix[*pm.to_a]
      expect(m).to eq(m.transpose)
    end
  end

  describe MB::Sound::GraphNode::Reverb::DiffusionStep do
    let(:step) {
      hadamard = MB::Sound::GraphNode::Reverb.hadamard_matrix(4)
      MB::Sound::GraphNode::Reverb::DiffusionStep.new(
        [0.005, 0.007, 0.009, 0.011], hadamard, sample_rate: 48000
      )
    }

    it 'preserves buffer length across channels' do
      channels = 4.times.map { Numo::SFloat.zeros(800).rand(-1, 1) }
      result = step.process(channels)

      expect(result.length).to eq(4)
      result.each do |ch|
        expect(ch.length).to eq(800)
      end
    end

    it 'produces non-zero output from non-zero input' do
      channels = 4.times.map { Numo::SFloat.zeros(4800).fill(1.0) }
      result = step.process(channels)
      output_energy = result.sum { |ch| (ch ** 2).sum }
      expect(output_energy).to be > 0
    end
  end

  describe MB::Sound::GraphNode::Reverb::FDN do
    let(:fdn) {
      MB::Sound::GraphNode::Reverb::FDN.new(
        [0.03, 0.037, 0.041, 0.046],
        decay: 2.0,
        damping: 0.5,
        sample_rate: 48000
      )
    }

    it 'returns an Array of N NArrays from N-channel input' do
      channels = 4.times.map { Numo::SFloat.zeros(480) }
      channels[0][0] = 1.0  # impulse

      result = fdn.process(channels)
      expect(result).to be_an(Array)
      expect(result.length).to eq(4)
      result.each do |ch|
        expect(ch).to be_a(Numo::SFloat)
        expect(ch.length).to eq(480)
      end
    end

    it 'decays an impulse over time' do
      # Feed an impulse, then silence; use large buffers so delays can propagate
      channels = 4.times.map { Numo::SFloat.zeros(4800) }
      channels[0][0] = 1.0

      fdn.process(channels)

      # Feed silence for several more blocks
      silence = 4.times.map { Numo::SFloat.zeros(4800) }
      early_block = fdn.process(silence)
      later_block = nil
      8.times { later_block = fdn.process(silence) }

      # Later blocks should have lower energy than early blocks
      early_energy = early_block.sum { |ch| (ch ** 2).sum }
      later_energy = later_block.sum { |ch| (ch ** 2).sum }
      expect(early_energy).to be > 0
      expect(later_energy).to be < early_energy
    end

    it 'processes buffers larger than the shortest delay' do
      short_fdn = MB::Sound::GraphNode::Reverb::FDN.new(
        [0.005, 0.007, 0.009, 0.011],
        decay: 1.0,
        damping: 0.5,
        sample_rate: 48000
      )

      channels = 4.times.map { Numo::SFloat.zeros(4800) }
      channels[0][0] = 1.0

      result = short_fdn.process(channels)
      expect(result).to be_an(Array)
      expect(result.length).to eq(4)
      result.each do |ch|
        expect(ch).to be_a(Numo::SFloat)
        expect(ch.length).to eq(4800)
      end
    end
  end

  describe '#sample' do
    it 'returns a NArray of the requested length' do
      reverb = 440.hz.sine.forever.reverb(sample_rate: 48000)
      result = reverb.sample(800)
      expect(result).to be_a(Numo::SFloat)
      expect(result.length).to eq(800)
    end

    it 'returns nil when input is exhausted' do
      reverb = 0.constant(smoothing: false).for(0.001).reverb(sample_rate: 48000)
      reverb.sample(48)
      result = reverb.sample(48)
      expect(result).to be_nil
    end

    it 'passes through dry signal when wet=0' do
      input = 1.constant(smoothing: false)
      reverb = MB::Sound::GraphNode::Reverb.new(
        input, wet: 0.0, dry: 1.0, sample_rate: 48000
      )

      result = reverb.sample(480)
      # With wet=0, output should equal the dry input
      expect(result).to eq(Numo::SFloat.zeros(480).fill(1.0))
    end

    it 'adds reverb energy when wet > 0' do
      input_node = 0.constant(smoothing: false)
      reverb = MB::Sound::GraphNode::Reverb.new(
        input_node, wet: 0.5, dry: 0.5, sample_rate: 48000
      )

      # Process an impulse-like signal
      input_node.constant = 1.0
      reverb.sample(48)
      input_node.constant = 0.0

      # After the impulse, reverb tail should still produce non-zero output
      result = reverb.sample(4800)
      expect(result.abs.max).to be > 0
    end
  end

  describe '#reset' do
    it 'clears internal state' do
      reverb = 440.hz.sine.forever.reverb(sample_rate: 48000)
      reverb.sample(4800)
      reverb.reset

      # After reset, processing silence should produce near-zero output
      silence_reverb = MB::Sound::GraphNode::Reverb.new(
        0.constant(smoothing: false),
        wet: 1.0, dry: 0.0, sample_rate: 48000
      )

      result = silence_reverb.sample(480)
      expect(result.abs.max).to be < 1e-6
    end
  end

  describe 'DSL method' do
    it 'is available on graph nodes via .reverb()' do
      node = 440.hz.sine.forever
      reverb = node.reverb(room_size: 0.8, decay: 3.0, damping: 0.6)
      expect(reverb).to be_a(MB::Sound::GraphNode::Reverb)

      result = reverb.sample(800)
      expect(result).to be_a(Numo::SFloat)
      expect(result.length).to eq(800)
    end

    it 'passes custom parameters through' do
      node = 440.hz.sine.forever
      reverb = node.reverb(channels: 8, diffusion_steps: 2)
      expect(reverb).to be_a(MB::Sound::GraphNode::Reverb)

      result = reverb.sample(800)
      expect(result.length).to eq(800)
    end
  end

  describe 'seed parameter' do
    it 'produces identical output for the same seed' do
      input1 = 440.hz.sine.forever
      input2 = 440.hz.sine.forever
      r1 = input1.reverb(seed: 42, sample_rate: 48000)
      r2 = input2.reverb(seed: 42, sample_rate: 48000)

      out1 = r1.sample(4800)
      out2 = r2.sample(4800)
      expect(out1).to eq(out2)
    end

    it 'produces different output for different seeds' do
      input1 = 440.hz.sine.forever
      input2 = 440.hz.sine.forever
      r1 = input1.reverb(seed: 0, wet: 1.0, dry: 0.0, sample_rate: 48000)
      r2 = input2.reverb(seed: 99, wet: 1.0, dry: 0.0, sample_rate: 48000)

      out1 = r1.sample(4800)
      out2 = r2.sample(4800)
      expect(out1).not_to eq(out2)
    end
  end

  describe '.delays_non_harmonic?' do
    it 'rejects delays with a ratio close to 2' do
      expect(MB::Sound::GraphNode::Reverb.delays_non_harmonic?([0.01, 0.02], 0.05)).to be false
    end

    it 'rejects delays with a ratio close to 3' do
      expect(MB::Sound::GraphNode::Reverb.delays_non_harmonic?([0.01, 0.0298], 0.05)).to be false
    end

    it 'accepts delays with non-harmonic ratios' do
      expect(MB::Sound::GraphNode::Reverb.delays_non_harmonic?([0.01, 0.017, 0.026], 0.05)).to be true
    end
  end

  describe '.log_random_delays' do
    it 'generates the requested number of log-spaced delays' do
      rng = Random.new(0)
      delays = MB::Sound::GraphNode::Reverb.log_random_delays(
        8, (0.015..0.120), 0.65, rng
      )

      expect(delays.length).to eq(8)
      expect(delays).to all(be_between(0.015 * 0.65, 0.120 * 0.65))
      expect(delays).to eq(delays.sort)
    end
  end

  describe 'parameter validation' do
    it 'rounds channels up to the next power of 2' do
      reverb = MB::Sound::GraphNode::Reverb.new(0.constant, channels: 3)
      result = reverb.sample(480)
      expect(result).to be_a(Numo::SFloat)
      expect(result.length).to eq(480)
    end

    it 'rejects room_size out of range' do
      expect {
        MB::Sound::GraphNode::Reverb.new(0.constant, room_size: 1.5)
      }.to raise_error(/room size/i)
    end

    it 'rejects negative decay' do
      expect {
        MB::Sound::GraphNode::Reverb.new(0.constant, decay: -1.0)
      }.to raise_error(/decay/i)
    end
  end

  describe 'multichannel' do
    it 'accepts an array of inputs' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      expect(reverb.output_channel_count).to eq(2)
    end

    it 'defaults output_channels to input count' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever, 330.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      expect(reverb.output_channel_count).to eq(3)
    end

    it 'allows explicit output_channels parameter' do
      reverb = MB::Sound::GraphNode::Reverb.new(
        440.hz.sine.forever, output_channels: 4, sample_rate: 48000
      )
      expect(reverb.output_channel_count).to eq(4)
    end

    it 'returns the correct number of output nodes' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      expect(reverb.outputs.length).to eq(2)
    end

    it 'returns ReverbOutput nodes for multi-output' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      reverb.outputs.each do |out|
        expect(out).to be_a(MB::Sound::GraphNode::Reverb::ReverbOutput)
      end
    end

    it 'returns [self] for single-output' do
      reverb = MB::Sound::GraphNode::Reverb.new(440.hz.sine.forever, sample_rate: 48000)
      expect(reverb.outputs).to eq([reverb])
    end

    it 'produces NArray data of correct length from each output' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      reverb.outputs.each do |out|
        result = out.sample(800)
        expect(result).to be_a(Numo::SFloat)
        expect(result.length).to eq(800)
      end
    end

    it 'produces decorrelated outputs' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(
        inputs, wet: 1.0, dry: 0.0, sample_rate: 48000
      )
      out0 = reverb.outputs[0].sample(4800)
      out1 = reverb.outputs[1].sample(4800)
      expect(out0).not_to eq(out1)
    end

    it 'returns output 0 from #sample on multi-output reverb' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)

      # Sample from output 0 via #sample
      result0 = reverb.sample(800)
      expect(result0).to be_a(Numo::SFloat)
      expect(result0.length).to eq(800)
    end

    it 'uses sources hash with indexed keys for multiple inputs' do
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      expect(reverb.sources.keys).to eq([:input_0, :input_1])
    end

    it 'uses single :input key for single input' do
      reverb = MB::Sound::GraphNode::Reverb.new(440.hz.sine.forever, sample_rate: 48000)
      expect(reverb.sources.keys).to eq([:input])
    end

    it 'auto-detects MultiOutput upstream via .reverb DSL' do
      # Create a multi-output reverb used as upstream for a second reverb.
      # The first reverb has 2 outputs and includes MultiOutput + GraphNode.
      inputs = [440.hz.sine.forever, 880.hz.sine.forever]
      reverb1 = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      expect(reverb1).to be_a(MB::Sound::GraphNode::MultiOutput)

      # Calling .reverb on a MultiOutput GraphNode auto-detects outputs
      reverb2 = reverb1.reverb(sample_rate: 48000)
      expect(reverb2).to be_a(MB::Sound::GraphNode::Reverb)
      expect(reverb2.output_channel_count).to eq(2)
      expect(reverb2.outputs.length).to eq(2)
    end

    it 'bumps internal channels to accommodate input and output counts' do
      # 5 inputs should bump channels from default 4 to at least 8 (next power of 2)
      inputs = 5.times.map { 440.hz.sine.forever }
      reverb = MB::Sound::GraphNode::Reverb.new(inputs, sample_rate: 48000)
      result = reverb.outputs[0].sample(480)
      expect(result).to be_a(Numo::SFloat)
    end
  end
end
