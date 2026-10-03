RSpec.describe(MB::Sound::GraphNode::MultitapDelay) do
  it 'can delay a single tap by a graph constant' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(5.constant(smoothing: false).named('Const'), 4.constant, sample_rate: 1)
    tap = dly.taps[0]

    expect(tap.sample(10)).to eq(Numo::SFloat[0, 0, 0, 0, 5, 5, 5, 5, 5, 5])
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 5, 5, 5, 5, 5, 5])

    tap.find_by_name('Const').constant = 3
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 3, 3, 3, 3, 3, 3])
  end

  it 'interpolates values when delayed by a fractional sample' do
    c = 0.constant(smoothing: false)
    d = 0.5.constant(smoothing: false)
    dly = MB::Sound::GraphNode::MultitapDelay.new(c, d, sample_rate: 1)
    tap = dly.taps[0]

    expect(tap.sample(5)).to eq(Numo::SFloat[0, 0, 0, 0, 0])

    c.constant = 1
    expect(tap.sample(5)).to eq(Numo::SFloat[0.5, 1, 1, 1, 1])

    # A quarter sample back from the new value: 0.75 * 2 + 0.25 * 1 (the
    # weights used to be reversed, giving 1.25)
    d.constant = 0.25
    c.constant = 2
    expect(tap.sample(3)).to eq(Numo::SFloat[1.75, 2, 2])
  end

  it 'keeps stored audio when a longer delay grows the buffer' do
    ramp = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(20000).seq], sample_rate: 1)
    delay = 1000.constant(smoothing: false, sample_rate: 1)
    dly = MB::Sound::GraphNode::MultitapDelay.new(ramp, delay, initial_buffer_seconds: 1500, sample_rate: 1)
    tap = dly.taps[0]
    tap.sample(4000)

    # 4500 samples back from 4000..4999 reaches 500 samples before the start
    delay.constant = 4500
    data = tap.sample(1000)
    expect(data.to_a).to eq((4000...5000).map { |v| [v - 4500, 0].max.to_f })
  end

  it 'can delay multiple taps by differing constant amounts' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(-2.constant, 2.5, 4.5, 0, sample_rate: 1)
    two, five, zero = dly.taps

    expect(two.sample(6)).to eq(Numo::SFloat[0, 0, -1, -2, -2, -2])
    expect(five.sample(6)).to eq(Numo::SFloat[0, 0, 0, 0, -1, -2])
    expect(zero.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])

    expect(two.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
    expect(five.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
    expect(zero.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
  end

  it 'can process complex data' do
    dly = MB::Sound::GraphNode::MultitapDelay.new((1+1i).constant, 0.5, sample_rate: 10)
    tap = dly.taps[0]

    expect(tap.sample(7)).to eq(Numo::SComplex[0, 0, 0, 0, 0, 1+1i, 1+1i])
    expect(tap.sample(2)).to eq(Numo::SComplex[1+1i, 1+1i])
  end

  it 'can delay by a variable amount' do
    d = 0.constant(smoothing: false).at_rate(1)
    tap = 1.hz.square.at(1).at_rate(2).multitap(d.clip_rate(1, sample_rate: 1), sample_rate: 1)[0]

    expect(tap.sample(6)).to eq(Numo::SFloat[1, -1, 1, -1, 1, -1])

    d.constant = 4

    expect(tap.sample(6)).to eq(Numo::SFloat[-1, -1, -1, -1, 1, -1])
  end

  pending 'variable delays'
  pending 'changing to complex data'

  pending
end
