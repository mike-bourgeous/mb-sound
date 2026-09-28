RSpec.describe(MB::Sound::GraphNode::GraphClock) do
  it 'counts the time sampled from its node' do
    node = 1.constant.at_rate(48000.0)
    clock = described_class.new(node)
    3.times { node.sample(800) }
    expect(clock.clock_now).to be_within(1e-9).of(0.05)
  end

  it 'counts time for nodes with an Integer sample rate' do
    node = 1.constant
    allow(node).to receive(:sample_rate).and_return(48000)
    clock = described_class.new(node)
    3.times { node.sample(800) }
    expect(clock.clock_now).to be_within(1e-9).of(0.05)
  end
end
