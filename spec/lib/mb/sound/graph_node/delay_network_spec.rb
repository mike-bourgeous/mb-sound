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

    it 'darkens each echo with high_cut: in the loop' do
      l, r = render_outputs(impulse.ping_pong(200.samples, feedback: 0.7, high_cut: 2000, low_cut: 100, dry: 0).outputs, [128], 1000)
      expect(l[200...350].abs.max).to be > r[400...550].abs.max / 0.7
      expect(l[200...350].abs.max).to be < 0.3
      expect(impulse.ping_pong(0.1, high_cut: 3000).to_ruby).to end_with('ping_pong(0.1, high_cut: 3000)')
    end

    it 'raises for more than two channels and unknown inputs' do
      three = MB::Sound::GraphNode::Channels.new([1.constant, 1.constant, 1.constant])
      expect { three.ping_pong(0.1) }.to raise_error(ArgumentError, /mono or stereo/)
      expect { 1.constant.ping_pong(0.1, input: :wide) }.to raise_error(ArgumentError, /:mono or :stereo/)
    end
  end

  describe 'loop filters (filters:, delay-dual-1)' do
    # The response of +filters+ (Cookbook settings) applied +times+ times
    # to an impulse, +count+ samples (Filter::Biquad#process, in doubles).
    def filtered_impulse(settings, times, count)
      x = Numo::DFloat.zeros(count)
      x[0] = 1
      times.times do
        settings.each { |type, hz| x = MB::Sound::Filter::Cookbook.new(type, 48000, hz, quality: Math.sqrt(0.5)).process(x) }
      end
      x
    end

    it 'runs each trip around the loop through the filters once' do
      cuts = [[:highpass, 300], [:lowpass, 2000]]
      filters = cuts.map { |type, hz| MB::Sound::Filter::Cookbook.new(type, 48000, hz, quality: Math.sqrt(0.5)) }
      net = described_class.new(inputs: [impulse], taps: [[0, 400.samples]], gains: [[0.5]], filters: [filters], interpolation: :linear)
      out, = render_outputs(net.taps, [128], 1600)

      expected = Numo::DFloat.zeros(1600)
      (1..3).each { |k| expected[(400 * k)..] += filtered_impulse(cuts, k, 1600 - 400 * k) * 0.5**(k - 1) }
      expect(out[0...400].abs.max).to eq(0)
      expect((out[0...1600] - expected).abs.max).to be < 1e-6
      expect(out[400...800].abs.max).to be > 0.05
    end

    it 'keeps the filters\' state per tap, and its samples at any buffer size' do
      make = -> {
        f = [MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 1500, quality: 0.7)]
        g = [MB::Sound::Filter::Cookbook.new(:highpass, 48000, 200, quality: 0.7), MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 4000, quality: 0.7)]
        described_class.new(inputs: [220.hz.saw.until(300.samples), nil], taps: [[0, 0.004], [1, 77.5.samples]], gains: [[nil, 0.6], [0.7, nil]], filters: [f, g]).taps
      }
      ref = render_outputs(make.(), [800], 20000)
      expect(ref[0].length).to be > 1000
      [[1, 127, 33], *slow_tier([[367, 368], [64]])].each do |sizes|
        expect(render_outputs(make.(), sizes, 20000)).to eq(ref)
      end
    end

    it 'raises for filters that are not biquads or a list of the wrong length' do
      expect { described_class.new(inputs: [impulse], taps: [[0, 0.1]], gains: [[0.5]], filters: [nil, nil]) }.to raise_error(ArgumentError, /one entry per tap/)
      expect { described_class.new(inputs: [impulse], taps: [[0, 0.1]], gains: [[0.5]], filters: [:lowpass]) }.to raise_error(ArgumentError, /Biquads/)
    end

    it 'follows sample rate changes and swaps filter states in a carry' do
      f = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 1000, quality: 0.7)
      net = described_class.new(inputs: [impulse], taps: [[0, 0.01]], gains: [[0.5]], filters: [[f]])
      co = net.instance_variable_get(:@filter_entries)[0][0].dup
      net.sample_rate = 96000
      expect(net.instance_variable_get(:@filter_entries)[0][0]).not_to eq(co)

      a = described_class.new(inputs: [impulse], taps: [[0, 0.01]], gains: [[0.5]], filters: [[f.dup]])
      b = described_class.new(inputs: [impulse], taps: [[0, 0.02]], gains: [[0.3]], filters: [[f.dup]])
      c = described_class.new(inputs: [impulse], taps: [[0, 0.02]], gains: [[0.3]])
      expect(b.carry_fits?(a)).to eq(true)
      expect(c.carry_fits?(a)).to eq(false)
      a.instance_variable_get(:@filter_entries)[0][1].fill(0.25)
      b.carry_adopt(a)
      expect(b.instance_variable_get(:@filter_entries)[0][1].to_a).to eq([0.25] * 4)
    end
  end

  describe '#dual_delay' do
    it 'echoes each side at its own time and feedback, hard left and right by default' do
      l, r = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: [0.5, 0.25], dry: 0, interpolation: :linear).outputs, [128], 1000)
      expect(nonzero(l, 3)).to eq([[100, 1.0], [200, 0.5], [300, 0.25]])
      expect(nonzero(r, 3)).to eq([[150, 1.0], [300, 0.25], [450, 0.0625]])
    end

    it 'scales and pans each echo with the dB-T\'s law: near side full, far side 1 - |position|' do
      l, r = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: 0, level: [1, 0.5], pan: [-0.5, 0.25], dry: 0).outputs, [128], 400)
      expect(nonzero(l)).to eq([[100, 1.0], [150, 0.375]])
      expect(nonzero(r)).to eq([[100, 0.5], [150, 0.5]])

      # (node positions and levels balance each echo instead, with the same gains)
      l2, r2 = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: 0, level: [1, 0.5.constant], pan: [-0.5.constant, 0.25], dry: 0).outputs, [128], 400)
      expect(nonzero(l2)).to eq(nonzero(l))
      expect(nonzero(r2)).to eq(nonzero(r))
    end

    it 'mixes with the measured one-knob law as mix_law: :balance, at equal power by default' do
      l, = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: 0, mix: 0.35, mix_law: :balance).outputs, [128], 400)
      expect(nonzero(l)).to eq([[0, 1.0], [100, 0.7]])
      l, = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: 0, mix: 0.75, mix_law: :balance).outputs, [128], 400)
      expect(nonzero(l)).to eq([[0, 0.5], [100, 1.0]])
      l, = render_outputs(impulse.dual_delay(100.samples, 150.samples, feedback: 0, mix: 0.25).outputs, [128], 400)
      expect(nonzero(l)).to eq([[0, Math.sqrt(0.75).round(6)], [100, 0.5]])
    end

    it 'feeds each side its own line with input: :stereo' do
      st = -> { MB::Sound::GraphNode::Channels.new([impulse, impulse.delay(10.samples, smooth: false) * 0.5]) }
      l, r = render_outputs(st.().dual_delay(100.samples, 100.samples, feedback: 0, input: :stereo, dry: 0).outputs, [64], 400)
      expect(nonzero(l)).to eq([[100, 1.0]])
      expect(nonzero(r)).to eq([[110, 0.5]])
      l, r = render_outputs(st.().dual_delay(100.samples, 100.samples, feedback: 0, dry: 0).outputs, [64], 400)
      expect(nonzero(l)).to eq([[100, 0.5], [110, 0.25]])
      expect(r).to eq(l)
    end

    it 'darkens and thins each repeat with high_cut: and low_cut: in the loop' do
      cut = impulse.dual_delay(200.samples, 300.samples, feedback: 0.6, high_cut: [2000, 8000], low_cut: 300, dry: 0)
      plain = impulse.dual_delay(200.samples, 300.samples, feedback: 0.6, dry: 0)
      cl, cr = render_outputs(cut.outputs, [800], 2000)
      pl, = render_outputs(plain.outputs, [800], 2000)
      # (a 2 kHz lowpass spreads an impulse's peak: each pass lowers it)
      peaks = (1..3).map { |k| cl[(200 * k)...(200 * k + 150)].abs.max }
      expect(peaks).to eq(peaks.sort.reverse)
      expect(peaks[0]).to be < 0.3
      expect(cr[300...450].abs.max).to be > peaks[0]
      expect(pl[200]).to eq(1)
    end

    it 'ends after its echoes ring out, at any buffer size, when echoes are fanned out (a tap read twice at its end)' do
      g = -> { 220.hz.saw.until(500.samples).dual_delay(0.01, 0.015, feedback: 0.3, pan: [0.2.constant, 0.6], high_cut: 5000) }
      ref = render_outputs(g.().outputs, [800], 100_000)
      expect(ref[0].length).to be_between(2000, 50_000)
      expect(render_outputs(g.().outputs, [97], 100_000)).to eq(ref)
    end

    it 'prints itself back as Ruby' do
      g = 220.hz.saw.at(0.3).dual_delay(0.1, 0.15, feedback: [0.4, 0.3], high_cut: 6000, low_cut: 150, pan: [-0.5, 0.5], mix: 0.5, mix_law: :balance)
      expect(g.to_ruby).to eq('220.hz.saw.at(0.3).dual_delay(0.1, 0.15, feedback: [0.4, 0.3], high_cut: 6000, low_cut: 150, pan: [-0.5, 0.5], mix: 0.5, mix_law: :balance)')
    end

    it 'raises for bad pans, laws, cuts, and inputs' do
      expect { 1.constant.dual_delay(0.1, 0.2, pan: 0.5) }.to raise_error(ArgumentError, /\[left position, right position\]/)
      expect { 1.constant.dual_delay(0.1, 0.2, mix_law: :log) }.to raise_error(ArgumentError, /mix_law/)
      expect { 1.constant.dual_delay(0.1, 0.2, pan_law: :linear) }.to raise_error(ArgumentError, /pan_law/)
      expect { 1.constant.dual_delay(0.1, 0.2, high_cut: 100.constant) }.to raise_error(ArgumentError, /high_cut/)
      expect { 1.constant.dual_delay(0.1, 0.2, low_cut: 30_000) }.to raise_error(ArgumentError, /low_cut/)
      expect { 1.constant.dual_delay(0.1, 0.2, feedback: [0.1, 0.2, 0.3]) }.to raise_error(ArgumentError, /feedback/)
      expect { 1.constant.dual_delay(0.1, 0.2, input: :wide) }.to raise_error(ArgumentError, /:mono or :stereo/)
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

  it 'declares long memory that a carry moves by adoption (NodeTraits)' do
    net = impulse.multitap(0.1, feedback: 0.5).outputs[0]
    traits = MB::Sound::NodeTraits.of(net.instance_variable_get(:@owner))
    expect(traits.memory).to eq(:long)
    expect(traits).to be_adopt
    expect(traits).not_to be_uncarried
  end
end
