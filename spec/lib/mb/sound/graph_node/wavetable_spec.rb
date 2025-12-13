RSpec.describe(MB::Sound::GraphNode::Wavetable) do
  let(:data) { Numo::SFloat[[1, -1, 1, 1, -1 -1], [0, 1, -1, 1, 0, -1]] }

  it 'can be created' do
    expect(120.hz.ramp.wavetable(wavetable: data, number: 0.constant)).to be_a(MB::Sound::GraphNode::Wavetable)
  end

  pending 'more tests'
end
