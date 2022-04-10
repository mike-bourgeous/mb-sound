RSpec.describe(MB::Sound::GraphNode::MultitapDelay) do
  it 'can delay a single tap by a graph constant' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(5.constant(smoothing: false).named('Const'), 4.constant, rate: 1)
    tap = dly.taps[0]

    expect(tap.sample(10)).to eq(Numo::SFloat[0, 0, 0, 0, 5, 5, 5, 5, 5, 5])
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 5, 5, 5, 5, 5, 5])

    tap.find_by_name('Const').constant = 3
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 3, 3, 3, 3, 3, 3])
  end

  it 'interpolates values when delayed by a fractional sample' do
    c = 0.constant(smoothing: false)
    d = 0.5.constant(smoothing: false)
    dly = MB::Sound::GraphNode::MultitapDelay.new(c, d, rate: 1)
    tap = dly.taps[0]

    expect(tap.sample(5)).to eq(Numo::SFloat[0, 0, 0, 0, 0])

    c.constant = 1
    expect(tap.sample(5)).to eq(Numo::SFloat[0.5, 1, 1, 1, 1])

    d.constant = 0.25
    c.constant = 2
    expect(tap.sample(3)).to eq(Numo::SFloat[1.25, 2, 2])
  end

  pending 'multiple taps'
  pending 'variable delays'
  pending 'changing to complex data'

  pending
end
