RSpec.describe(MB::Sound::GraphNode::Channels) do
  let(:left) { 1.constant }
  let(:right) { 2.constant }
  let(:bundle) { MB::Sound.stereo(left, right) }

  describe 'construction' do
    it 'is created by stereo, channels, Array#channels, and GraphNode#stereo' do
      expect(bundle.outputs).to eq([left, right])
      expect(MB::Sound.channels(left, right, 3.constant).channel_count).to eq(3)
      expect(MB::Sound.channels([left, right]).outputs).to eq([left, right])
      expect([left, right].channels.outputs).to eq([left, right])
      expect(left.stereo.outputs).to eq([left, left])
    end

    it 'flattens multi-output nodes into channels' do
      nested = MB::Sound.channels(bundle, 3.constant)
      expect(nested.channel_count).to eq(3)
      expect(nested[0]).to equal(left)
    end

    it 'rejects things that are not nodes and empty bundles' do
      expect { MB::Sound::GraphNode::Channels.new([left, 5]) }.to raise_error(ArgumentError, /graph nodes.*constant/)
      expect { MB::Sound.channels(left, 5) }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound.channels }.to raise_error(ArgumentError, /at least one/)
    end
  end

  describe 'Array-like access' do
    it 'supports indexing, iteration, and destructuring' do
      l, r = bundle
      expect([l, r]).to eq([left, right])
      expect(bundle[1]).to equal(right)
      expect(bundle.map(&:constant)).to eq([1, 2])
      expect(bundle.length).to eq(2)
      expect(bundle.to_a).to eq([left, right])
      expect(Array(bundle)).to eq([left, right])
    end

    it 'looks up named channels by name, and keeps names through per-channel calls' do
      named = MB::Sound::GraphNode::Channels.new([left, right, 3.constant], names: [:kick, 'snare', :hat])
      expect(named.names).to eq([:kick, :snare, :hat])
      expect(named[:snare]).to equal(right)
      expect(named['kick']).to equal(left)
      expect(named[0..1]).to eq([left, right])
      expect(named.channel_index(:hat)).to eq(2)
      expect(named.to_h).to eq(kick: left, snare: right, hat: named[2])
      expect { named[:clap] }.to raise_error(KeyError, /No channel named :clap.*:kick, :snare, :hat/)
      expect { bundle[:left] }.to raise_error(KeyError, /unnamed/)
      expect(bundle.names).to be_nil
      expect(bundle.to_h).to eq(channel_1: left, channel_2: right)

      scaled = named * 2
      expect(scaled.names).to eq([:kick, :snare, :hat])
      expect(scaled[:snare].sample(1)[0]).to eq(4)
      expect(named.mono.channel_count).to eq(1)
    end

    it 'rejects channel names that do not fit' do
      expect { MB::Sound::GraphNode::Channels.new([left, right], names: [:a]) }.to raise_error(ArgumentError, /1 channel names for 2/)
      expect { MB::Sound::GraphNode::Channels.new([left, right], names: [:a, 'a']) }.to raise_error(ArgumentError, /unique/)
    end

    it 'does not act like Enumerable#filter' do
      expect(bundle).not_to be_a(Enumerable)
    end
  end

  describe 'conversions' do
    # The first sample of each channel of +node+.
    def firsts(node)
      node.outputs.map { |o| o.sample(4)[0].round(4) }
    end

    it 'pans single-channel nodes with equal power' do
      expect(firsts(1.constant.pan(-1))).to eq([1, 0])
      expect(firsts(1.constant.pan(0))).to eq([0.7071, 0.7071])
      expect(firsts(1.constant.pan(1))).to eq([0, 1])
      expect(firsts(1.constant.pan(MB::Sound::GraphNode::Constant.new(1, sample_rate: 48000)))).to eq([0, 1])
    end

    it 'rejects unknown pan laws and out-of-range positions' do
      expect { 1.constant.pan(0, law: :sideways) }.to raise_error(ArgumentError, /law/)
      expect { 1.constant.pan(2) }.to raise_error(ArgumentError, /position must be in -1..1/)
      expect { bundle.pan(2) }.to raise_error(ArgumentError, /position must be in -1..1/)
    end

    it 'pans with the linear and -4.5 dB laws' do
      expect(firsts(1.constant.pan(0, law: :linear))).to eq([0.5, 0.5])
      expect(firsts(1.constant.pan(0, law: :minus_4_5db))).to eq([0.5 ** 0.75, 0.5 ** 0.75].map { |v| v.round(4) })
      expect(firsts(1.constant.pan(-0.5, law: :linear))).to eq([0.75, 0.25])
    end

    it 'balances stereo bundles and pans one-channel bundles' do
      even = MB::Sound.stereo(1.constant, 1.constant)
      expect(firsts(even.pan(-1))).to eq([1, 0])
      expect(firsts(even.pan(0))).to eq([1, 1])
      expect(firsts(even.pan(0.5))).to eq([0.5412, 1])
      expect(firsts(even.pan(MB::Sound::GraphNode::Constant.new(-0.5, sample_rate: 48000)))).to eq([1, 0.5412])
      expect(firsts(MB::Sound.channels(1.constant).pan(1))).to eq([0, 1])
      expect { MB::Sound.channels(left, right, 3.constant).pan(0) }.to raise_error(ArgumentError, /1 or 2 channels/)
    end

    it 'mixes down, swaps, and picks channels' do
      expect(bundle.mono.sample(4)[0]).to eq(1.5)
      expect(bundle.mixdown.sample(4)[0]).to eq(1.5)
      expect(1.constant.mono.constant).to eq(1)
      expect(firsts(bundle.swap)).to eq([2, 1])
      expect(bundle.left).to equal(left)
      expect(bundle.right).to equal(right)
      expect(bundle.stereo).to equal(bundle)
      expect(firsts(MB::Sound.channels(left).stereo)).to eq([1, 1])
    end

    it 'converts to and from mid/side and changes width' do
      expect(firsts(bundle.mid_side)).to eq([1.5, -0.5])
      expect(firsts(bundle.mid_side.from_mid_side)).to eq([1, 2])
      expect(firsts(bundle.width(0))).to eq([1.5, 1.5])
      expect(firsts(bundle.width(2))).to eq([0.5, 2.5])
    end

    it 'requires stereo for stereo-only conversions' do
      three = MB::Sound.channels(left, right, 3.constant)
      expect { three.swap }.to raise_error(ArgumentError, /stereo/)
      expect { three.stereo }.to raise_error(ArgumentError, /mix down/)
      expect { MB::Sound.channels(left).right }.to raise_error(ArgumentError, /no right/)
    end
  end

  describe 'methods that return bundles' do
    it 'returns bundles from reverbs, multitap delays, split inputs, and stereo synth voices' do
      expect(bundle.reverb(:room)).to be_a(described_class).and(have_attributes(channel_count: 2))
      expect(1.constant.reverb(:room, output_channels: 2)).to be_a(described_class)
      expect(1.constant.reverb(:room)).to be_a(MB::Sound::GraphNode::Reverb)

      taps = 1.constant.multitap(0.1, 0.2)
      expect(taps).to be_a(described_class)
      l, r = taps
      expect(l).to be_a(MB::Sound::GraphNode::MultitapDelay::DelayTap)

      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(10), Numo::SFloat.zeros(10)])
      expect(input.split).to be_a(described_class)
      expect(input.outputs).to be_a(Array)

      chords = MB::Sound.seq(MB::Sound::A2, MB::Sound::C3).n1.loop
      expect(chords.synth(voices: 2) { |v| v.tone.at(1).stereo }).to be_a(described_class)
      expect(chords.synth(voices: 2) { |v| v.tone.at(1) }).not_to be_a(described_class)
    end

    it 'runs a bundle through one reverb with an input per channel' do
      reverb = bundle.reverb(:room)[0].graph.grep(MB::Sound::GraphNode::Reverb).first
      expect(reverb.sources.length).to eq(2) # one input per channel (padded with silence for the tail)
      expect(reverb.graph).to include(left, right)
    end
  end

  it 'is a multi-output node with its channels as sources' do
    expect(bundle).to be_a(MB::Sound::GraphNode::MultiOutput)
    expect(bundle.channel_count).to eq(2)
    expect(bundle.sources).to eq(channel_1: left, channel_2: right)
    expect(bundle.graph).to include(left, right)
    expect(bundle.sample_rate).to eq(48000)
  end

  it 'explains that bundles are sampled through their channels' do
    expect { bundle.sample(10) }.to raise_error(NotImplementedError, /sample its channels/)
  end

  it 'plays each channel on its own output channel in a Session' do
    session = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_size: 800, realtime: false, raise_errors: true)
    session.add(bundle)
    expect(session.process_buffer.map { |c| c[0] }).to eq([1, 2])
    session.add([MB::Sound.stereo(3.constant, 4.constant)], at: :now)
    expect(session.process_buffer.map { |c| c[0] }).to eq([4, 6])
  ensure
    session&.close
    MB::Sound.rewind
  end

  it 'plays with MB::Sound.play' do
    ENV['OUTPUT_TYPE'] = 'null'
    expect { MB::Sound.play(bundle.map { |c| c.until(0.01) }.channels, quiet: true) }.not_to raise_error
  ensure
    ENV.delete('OUTPUT_TYPE')
  end

  it 'has every channel conversion that single nodes have' do
    missing = MB::Sound::GraphNode::ChannelMethods.public_instance_methods(false).reject { |m|
      MB::Sound::GraphNode::Channels.public_method_defined?(m)
    }
    expect(missing).to eq([])
  end

  it 'mixes a bundle with a matrix' do
    b = MB::Sound.stereo(1.constant, 2.constant)
    l, r = b.matrix([[1, 0.5], [0.5, 1]]).outputs.map { |o| o.sample(2)[0] }
    expect([l, r]).to eq([2, 2.5])
    expect(b.matrix([[1, 1]]).sample(2).to_a).to eq([3, 3])
  end
end
