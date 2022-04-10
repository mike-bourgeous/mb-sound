RSpec.describe(MB::Sound::GraphNode::MultitapDelay) do
  it 'can delay a single tap by a constant amount' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(5.constant(smoothing: false).named('Const'), 4.constant.named('Delay'), rate: 1)
    tap = dly.taps[0]

    expect(tap.sample(10)).to eq(Numo::SFloat[0, 0, 0, 0, 5, 5, 5, 5, 5, 5])
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 5, 5, 5, 5, 5, 5])

    tap.find_by_name('Const').constant = 3
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 3, 3, 3, 3, 3, 3])
  end

  pending 'multiple taps'
  pending 'variable delays'
  pending 'changing to complex data'

  pending
end
