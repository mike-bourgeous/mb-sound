RSpec.describe(MB::Sound::GraphNode::DelayNetwork) do
  # Renders every output of +outs+ (nodes) in buffers cycling through
  # +sizes+, reading each output in turn every buffer, until they all end
  # or +limit+ samples.  Returns one SFloat per output.
  def render_outputs(outs, sizes, limit)
    lists = outs.map { [] }
    n = 0
    i = 0
    while n < limit
      c = sizes[i % sizes.length]
      bufs = outs.map { |o| o.sample(c) }
      break if bufs.all?(&:nil?)

      bufs.each_with_index { |b, k| lists[k] << b.dup if b }
      n += bufs.compact.map(&:length).max
      i += 1
    end
    lists.map { |l| SpecBuffers.join(l) || Numo::SFloat[] }
  end

  # A one-sample impulse that then ends.
  def impulse
    1.constant.until(1.samples)
  end

  def nonzero(buf, count = 6)
    buf.to_a.each_with_index.select { |v, _| v.abs > 1e-9 }.first(count).map { |v, i| [i, v.round(6)] }
  end

  describe '#multitap with feedback:' do
    it 'regenerates every tap with its own gain' do
      a, b = impulse.multitap(100.samples, 250.samples, feedback: [0.5, 0.25], interpolation: :linear).to_a
      la, lb = render_outputs([a, b], [128], 2000)
      expect(nonzero(la)).to eq([[100, 1.0], [200, 0.5], [300, 0.25], [350, 0.25], [400, 0.125], [450, 0.25]])
      expect(nonzero(lb, 3)).to eq([[250, 1.0], [350, 0.5], [450, 0.25]])
    end

    it 'shares one gain evenly between the taps' do
      a, b = impulse.multitap(100.samples, 300.samples, feedback: 0.8).to_a
      la, = render_outputs([a, b], [800], 1000)
      # first regeneration: 0.4 from each tap
      expect(nonzero(la, 3)).to eq([[100, 1.0], [200, 0.4], [300, 0.16]])
    end

    # (the maintainer, 2026-10-30: "Per head"; a single number stays the
    # loop's shared gain)
    it 'prints per-head and shared gains back as Ruby, and a saved graph document plays the same samples' do
      make = -> { MB::Sound.with_seed(2) { (220.hz.saw.at(0.3) * MB::Sound.adsr(0, 0.05, 0, 0)).multitap(0.01, 0.02, 0.03, feedback: [0.4, 0, 0.3]).mixdown } }
      g = make.()
      expect(g.to_ruby).to eq('(220.hz.saw.at(0.3) * adsr(0, 0.05, 0, 0)).multitap(0.01, 0.02, 0.03, feedback: [0.4, 0, 0.3]).mono')
      expect(1.constant.multitap(0.1, 0.2, feedback: 0.5).mixdown.to_ruby).to eq('1.constant.multitap(0.1, 0.2, feedback: 0.5).mono')
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
      ref = make.()
      expect(Array.new(10) { loaded.sample(800).dup }).to eq(Array.new(10) { ref.sample(800).dup })
    end

    it 'gives MultitapDelay samples and ending with zero gains' do
      make = ->(fb) {
        MB::Sound.seed(1)
        sig = 220.hz.saw.at(0.5).until(0.01) # (ends, so the taps ring out)
        sig.multitap(0.001, 37.samples, interpolation: :cubic, **(fb ? { feedback: [0, 0] } : {})).to_a
      }
      plain = render_outputs(make.(false), [128], 48000)
      net = render_outputs(make.(true), [128], 48000)
      expect(net.map(&:length)).to eq(plain.map(&:length))
      expect(net).to eq(plain)
    end

    it 'gives the same samples and the same ending at any buffer size' do
      make = -> {
        MB::Sound.seed(1)
        sig = 220.hz.saw.at(0.5).until(0.02)
        lfo = 3.hz.lfo.at(0.002..0.004)
        sig.multitap(0.003, lfo, 1.n32, feedback: [0.4, 2.hz.lfo.at(0.1..0.3), -0.2], smooth: true).to_a
      }
      ref = render_outputs(make.(), [800], 480_000)
      expect(ref[0].length).to be < 480_000
      expect(ref[0].abs.max).to be > 0.1
      [[1], [7], [367, 368], [64]].each do |sizes|
        next if sizes == [1] && !SPEC_SLOW
        out = render_outputs(make.(), sizes, 480_000)
        expect(out.map(&:length)).to eq(ref.map(&:length)), "length at #{sizes}"
        expect(out).to eq(ref), "samples at #{sizes}"
      end
    end

    it 'rings out until the repeats fall below -90 dB' do
      a, = impulse.multitap(100.samples, feedback: [0.5]).to_a
      la, = render_outputs([a], [128], 48000)
      # The line gets 0.5^n at 100 n; 0.5^14 (sample 1400) is the last
      # write above -90 dB, then one more delay plus the margin
      expect(0.5**14).to be > MB::Sound::QuietRun::QUIET
      expect(0.5**15).to be < MB::Sound::QuietRun::QUIET
      expect(la.length).to eq(1401 + 100 + MB::Sound::DelayLine::MARGIN)
    end

    it 'raises for a gain list of the wrong length' do
      expect { 1.constant.multitap(0.1, 0.2, feedback: [0.5]) }.to raise_error(ArgumentError, /one gain per tap/)
    end
  end

  describe '#ping_pong' do
    it 'bounces echoes left and right, each feedback times the last' do
      l, r = render_outputs(impulse.ping_pong(100.samples, feedback: 0.5).outputs, [128], 2000)
      expect(nonzero(l, 4)).to eq([[0, 1.0], [100, 1.0], [300, 0.25], [500, 0.0625]])
      expect(nonzero(r, 4)).to eq([[0, 1.0], [200, 0.5], [400, 0.125], [600, 0.03125]])
    end

    it 'puts every echo in the middle with spread 0' do
      l, r = render_outputs(impulse.ping_pong(100.samples, feedback: 0.5, spread: 0, dry: 0).outputs, [128], 2000)
      expect(l).to eq(r)
      expect(nonzero(l, 2)).to eq([[100, 0.5], [200, 0.25]])
    end

    it 'feeds each side of a stereo input into its own line with input: :stereo' do
      st = MB::Sound::GraphNode::Channels.new([impulse, impulse.delay(10.samples, smooth: false) * 0.5])
      l, r = render_outputs(st.ping_pong(100.samples, feedback: 0.5, input: :stereo, dry: 0).outputs, [64], 1000)
      expect(nonzero(l, 3)).to eq([[100, 1.0], [210, 0.25], [300, 0.25]])
      expect(nonzero(r, 3)).to eq([[110, 0.5], [200, 0.5], [310, 0.125]])
    end

    it 'crossfades dry and wet at equal power with mix: (delays-2)' do
      l, = render_outputs(impulse.ping_pong(100.samples, feedback: 0.5, mix: 0.25).outputs, [128], 400)
      expect(nonzero(l, 2)).to eq([[0, Math.sqrt(0.75).round(6)], [100, 0.5]])
      l, = render_outputs(impulse.ping_pong(100.samples, feedback: 0.5, mix: 0.25.constant).outputs, [128], 400)
      expect(nonzero(l, 2)).to eq([[0, Math.sqrt(0.75).round(6)], [100, 0.5]])
    end

    it 'prints itself back as Ruby' do
      g = 220.hz.saw.at(0.3).ping_pong(0.1, feedback: 0.4, spread: 0.6, mix: 0.3)
      expect(g.to_ruby).to eq('220.hz.saw.at(0.3).ping_pong(0.1, feedback: 0.4, spread: 0.6, mix: 0.3)')
    end

    it 'raises for more than two channels and unknown inputs' do
      three = MB::Sound::GraphNode::Channels.new([1.constant, 1.constant, 1.constant])
      expect { three.ping_pong(0.1) }.to raise_error(ArgumentError, /mono or stereo/)
      expect { 1.constant.ping_pong(0.1, input: :wide) }.to raise_error(ArgumentError, /:mono or :stereo/)
    end
  end

  describe '#haas' do
    it 'delays one side' do
      l, r = render_outputs(impulse.haas(10.samples).outputs, [64], 100)
      expect(nonzero(l)).to eq([[0, 1.0]])
      expect(nonzero(r)).to eq([[10, 1.0]])

      l, r = render_outputs(impulse.haas(5.samples, side: :left, level: 0.5).outputs, [64], 100)
      expect(nonzero(l)).to eq([[5, 0.5]])
      expect(nonzero(r)).to eq([[0, 1.0]])
    end
  end

  it 'declares long memory that a carry starts fresh (NodeTraits)' do
    net = impulse.multitap(0.1, feedback: 0.5).outputs[0]
    traits = MB::Sound::NodeTraits.of(net.instance_variable_get(:@owner))
    expect(traits.memory).to eq(:long)
    expect(traits).to be_uncarried
  end
end
