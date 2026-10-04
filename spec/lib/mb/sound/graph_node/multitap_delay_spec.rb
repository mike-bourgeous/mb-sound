RSpec.describe(MB::Sound::GraphNode::MultitapDelay) do
  it 'can delay a single tap by a graph constant' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(5.constant(smoothing: false).named('Const'), 4.constant.samples)
    tap = dly.taps[0]

    expect(tap.sample(10)).to eq(Numo::SFloat[0, 0, 0, 0, 5, 5, 5, 5, 5, 5])
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 5, 5, 5, 5, 5, 5])

    tap.find_by_name('Const').constant = 3
    expect(tap.sample(10)).to eq(Numo::SFloat[5, 5, 5, 5, 3, 3, 3, 3, 3, 3])
  end

  it 'interpolates values when delayed by a fractional sample' do
    c = 0.constant(smoothing: false)
    d = 0.5.constant(smoothing: false)
    dly = MB::Sound::GraphNode::MultitapDelay.new(c, d.samples, interpolation: :linear)
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
    dly = MB::Sound::GraphNode::MultitapDelay.new(ramp, delay.samples, initial_buffer: 1500.samples)
    tap = dly.taps[0]
    tap.sample(4000)

    # 4500 samples back from 4000..4999 reaches 500 samples before the start
    delay.constant = 4500
    data = tap.sample(1000)
    expect(data.to_a).to eq((4000...5000).map { |v| [v - 4500, 0].max.to_f })
  end

  describe 'smoothing' do
    let(:ramp) { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(400).seq], sample_rate: 1) }

    it 'jumps by default' do
      delay = 10.constant(smoothing: false, sample_rate: 1)
      tap = MB::Sound::GraphNode::MultitapDelay.new(ramp, delay.samples, interpolation: :linear).taps[0]
      tap.sample(100)
      delay.constant = 30
      expect(tap.sample(5).to_a).to eq([70, 71, 72, 73, 74])
    end

    it 'glides delay changes at the smoothing rate, starting at the first delay' do
      delay = 10.constant(smoothing: false, sample_rate: 1)
      mtd = MB::Sound::GraphNode::MultitapDelay.new(ramp, delay.samples, interpolation: :linear, smoothing: 0.5)
      tap = mtd.taps[0]

      # No glide up from zero at the start
      expect(tap.sample(100).to_a[10..14]).to eq([0, 1, 2, 3, 4])

      # Half a sample of delay per sample: the read point moves at 0.5x
      delay.constant = 30
      expect(tap.sample(4).to_a).to eq([89.5, 90, 90.5, 91])
    end

    it 'keeps the smoothing rate in seconds per second when oversampled' do
      [1, 2, 4].each do |os|
        jump = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(48000).fill(0.03).tap { |d| d[0...4800] = 0.01 }])
          .with_buffer(800).resample(mode: :libsamplerate_fastest)
        sig = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(48000).seq / 48000.0]).with_buffer(800).resample(mode: :libsamplerate_fastest)
        node = sig.multitap(jump, smoothing: 0.1, interpolation: :linear)[0].oversample(os)
        out = Numo::SFloat.zeros(0).concatenate(*Array.new(30) { node.sample(800).dup })
        d = Numo::SFloat.new(out.length).seq / 48000.0 - out

        # Starts at the first delay, then glides 0.02 s in 0.2 s
        expect(d[2400]).to be_within(2e-4).of(0.01), "at #{os}x"
        expect(d[4800 + 4800]).to be_within(2e-4).of(0.02), "at #{os}x"
        expect(d[4800 + 9600 + 480]).to be_within(2e-4).of(0.03), "at #{os}x"
      end
    end

    it 'is available from the DSL' do
      taps = 100.hz.multitap(0.01, 0.02, smoothing: true)
      expect(taps.map { |t| t.instance_variable_get(:@smoother) }.to_a).to all(be_a(MB::Sound::Filter::LinearFollower))
    end
  end

  it 'can delay multiple taps by differing constant amounts' do
    dly = MB::Sound::GraphNode::MultitapDelay.new(-2.constant, 2.5.samples, 4.5.samples, 0.samples, interpolation: :linear)
    two, five, zero = dly.taps

    expect(two.sample(6)).to eq(Numo::SFloat[0, 0, -1, -2, -2, -2])
    expect(five.sample(6)).to eq(Numo::SFloat[0, 0, 0, 0, -1, -2])
    expect(zero.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])

    expect(two.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
    expect(five.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
    expect(zero.sample(6)).to eq(Numo::SFloat[-2, -2, -2, -2, -2, -2])
  end

  it 'can process complex data' do
    dly = MB::Sound::GraphNode::MultitapDelay.new((1+1i).constant, 5.samples)
    tap = dly.taps[0]

    expect(tap.sample(7)).to eq(Numo::SComplex[0, 0, 0, 0, 0, 1+1i, 1+1i])
    expect(tap.sample(2)).to eq(Numo::SComplex[1+1i, 1+1i])
  end

  it 'can delay by a variable amount' do
    d = 0.constant(smoothing: false).at_rate(1)
    tap = 1.hz.asquare.at(1).at_rate(2).multitap(d.clip_rate(1, sample_rate: 1).samples)[0]

    expect(tap.sample(6)).to eq(Numo::SFloat[1, -1, 1, -1, 1, -1])

    d.constant = 4

    expect(tap.sample(6)).to eq(Numo::SFloat[-1, -1, -1, -1, 1, -1])
  end

  pending 'variable delays'
  pending 'changing to complex data'

  pending
end
