RSpec.describe(MB::Sound::InputChannelSplit) do
  it 'can be created' do
    l, r = MB::Sound.file_input('sounds/synth0.flac').split
    expect(l).to be_a(MB::Sound::InputChannelSplit::InputChannelNode)
    expect(r).to be_a(MB::Sound::InputChannelSplit::InputChannelNode)
  end

  it 'can limit the number of channels' do
    l, r = MB::Sound.file_input('sounds/synth0.flac').split(max_channels: 1)
    expect(l).to be_a(MB::Sound::InputChannelSplit::InputChannelNode)
    expect(r).to eq(nil)
  end

  describe 'InputChannelNode#sample' do
    it 'returns different data when channels differ' do
      l, r = MB::Sound.file_input('sounds/synth0.flac').split
      a = l.sample(800)
      b = r.sample(800)
      expect(a).not_to eq(b)
    end

    it 'returns different data on subsequent reads' do
      l, _ = MB::Sound.file_input('sounds/synth0.flac').split(max_channels: 1)
      a = l.sample(800)
      b = l.sample(800)
      expect(a).not_to eq(b)
    end
  end
end
