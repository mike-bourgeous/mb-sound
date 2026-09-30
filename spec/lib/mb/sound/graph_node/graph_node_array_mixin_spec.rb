RSpec.describe(MB::Sound::GraphNode::GraphNodeArrayMixin) do
  # More tests in the GraphNodeInput spec
  it 'adds the as_input method to Arrays' do
    expect([]).to respond_to(:as_input)
  end

  describe '#as_input' do
    it 'raises an error if the array is empty' do
      expect { [].as_input }.to raise_error(/GraphNodes/)
    end

    it 'raises an error if any elements are not graph nodes' do
      expect { [1.constant, 2].as_input }.to raise_error(/GraphNodes/)
    end

    it 'produces a readable input given an array of nodes' do
      expect([1.constant].as_input.read(3)).to eq([Numo::SFloat.ones(3)])
      expect([-1.constant, -2.constant].as_input.read(3)).to eq([Numo::SFloat[-1,-1,-1], Numo::SFloat[-2,-2,-2]])
    end
  end

  describe '#reverb' do
    it 'raises an error for empty arrays or elements that are not graph nodes' do
      expect { [].reverb }.to raise_error(ArgumentError, /GraphNodes/)
      expect { [1.constant, 2].reverb }.to raise_error(ArgumentError, /GraphNodes/)
    end

    it 'returns one output per input by default' do
      out = [finite(1.constant, 0.1), finite(-1.constant, 0.1)].reverb(:hall)
      expect(out.length).to eq(2)
      expect(out).to all(be_a(MB::Sound::GraphNode))
    end

    it 'accepts a different number of output channels' do
      expect([1.constant, 1.constant].reverb(:room, output_channels: 3).length).to eq(3)
      expect([1.constant, 1.constant].reverb(:room, output_channels: 1)).to be_a(MB::Sound::GraphNode::Reverb)
      expect([1.constant, 1.constant].reverb(:room)).to be_a(MB::Sound::GraphNode::Channels)
    end

    it 'mixes every input into each output' do
      l, r = [finite(0.5.constant, 0.05), finite(0.constant, 0.05)].reverb(:hall, dry: 0)
      data = [l, r].map { |c| Array.new(20) { c.sample(800)&.dup }.compact.reduce(:concatenate) }
      expect(data[1].abs.max).to be > 0.001
    end

    it 'lets the tail ring out after finite inputs end' do
      l, r = [finite(0.5.constant, 0.05), finite(0.5.constant, 0.05)].reverb(:hall)
      frames = [0, 0]
      200.times do
        data = [l, r].map { |c| c.sample(800) }
        break if data.any? { |d| d.nil? || d.empty? }
        data.each_with_index { |d, i| frames[i] += d.length }
      end
      expect(frames).to all(be > 48000)
      expect(frames[0]).to eq(frames[1])
    end
  end
end
