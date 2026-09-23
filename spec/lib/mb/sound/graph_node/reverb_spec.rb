RSpec.describe(MB::Sound::GraphNode::Reverb) do
  it 'has feedback sources if show_internals is true' do
    # Using fewer channels and stages to reduce the exponential path explosion that causes warnings about infinite loops
    expect(100.hz.reverb(channels: 2, stages: 1, show_internals: true).graph_edges(feedback: true)).not_to be_empty
  end

  it 'does not have feedback sources if show_internals is false' do
    expect(100.hz.reverb.graph_edges(feedback: true)).to be_empty
  end
end
