RSpec.describe(MB::Sound::GraphNode::InputChannelSplit) do
  it 'can be created' do
    l, r = MB::Sound.file_input('sounds/synth0.flac').split
    expect(l).to be_a(MB::Sound::GraphNode::InputChannelSplit::InputChannelNode)
    expect(r).to be_a(MB::Sound::GraphNode::InputChannelSplit::InputChannelNode)
  end

  it 'can limit the number of channels' do
    l, r = MB::Sound.file_input('sounds/synth0.flac').split(max_channels: 1)
    expect(l).to be_a(MB::Sound::GraphNode::IOSampleMixin)
    expect(r).to eq(nil)
  end

  it 'cannot change sample rates' do
    expect { MB::Sound.file_input('sounds/synth0.flac').split[0].sample_rate = 5 }.to raise_error(NotImplementedError, /sample rate/)
  end

  describe '::InputChannelNode#sample' do
    it 'returns different data when channels differ' do
      l, r = MB::Sound.file_input('sounds/synth0.flac').split
      a = l.sample(800).dup
      b = r.sample(800).dup
      expect(a).not_to eq(b)
    end

    it 'returns different data on subsequent reads' do
      l, _ = MB::Sound.file_input('sounds/synth0.flac').split(max_channels: 1)
      a = l.sample(800).dup
      b = l.sample(800).dup
      expect(a).not_to eq(b)
    end

    it 'can be called more than once for one channel without calling another channel' do
      ai = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1,2,3,4,5], Numo::SFloat[5,4,3,2,1]], buffer_size: 2)
      l, r = ai.split

      expect(l.sample(5)).to eq(Numo::SFloat[1,2,3,4,5])
      expect(r.sample(5)).to eq(Numo::SFloat[5,4,3,2,1])
    end

    it "raises an error if one channel's buffer overflows" do
      l, _ = MB::Sound::NullInput.new(channels: 2, buffer_size: 800).split
      l.sample(48000)
      expect { l.sample(1) }.to raise_error(MB::Sound::GraphNode::InputChannelSplit::ChannelBufferOverflow)
    end

    it 'returns nil when the input is out of data' do
      l = MB::Sound::NullInput.new(channels: 1, length: 5, buffer_size: 800).split[0]
      expect(l.sample(50)).to eq(Numo::SFloat[0,0,0,0,0])
      expect(l.sample(1)).to eq(nil)
    end
  end
end
