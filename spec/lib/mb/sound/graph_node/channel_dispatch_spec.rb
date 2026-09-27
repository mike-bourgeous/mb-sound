RSpec.describe(MB::Sound::GraphNode::ChannelDispatch) do
  let(:bundle) { MB::Sound.stereo(1.constant, 2.constant) }

  # The first sample of each channel of +node+.
  def firsts(node)
    node.outputs.map { |o| o.sample(4)[0].round(6) }
  end

  describe 'running DSL methods per channel' do
    it 'runs methods on each channel of a bundle' do
      result = bundle.softclip(0.5, 0.9)
      expect(result).to be_a(MB::Sound::GraphNode::Channels)
      expect(firsts(result)).to eq(firsts(MB::Sound.stereo(1.constant.softclip(0.5, 0.9), 2.constant.softclip(0.5, 0.9))))
    end

    it 'leaves single-channel nodes unchanged' do
      expect(1.constant.softclip).to be_a(MB::Sound::Filter::SampleWrapper)
      expect(1.constant * 2).to be_a(MB::Sound::GraphNode)
    end

    it 'keeps chaining through several methods' do
      result = bundle.filter(:lowpass, cutoff: 1000).softclip * 0.5
      expect(result.channel_count).to eq(2)
    end
  end

  describe 'arithmetic' do
    it 'combines bundles with bundles, nodes, and numbers on either side' do
      expect(firsts(bundle * 10)).to eq([10, 20])
      expect(firsts(bundle + bundle)).to eq([2, 4])
      expect(firsts(3.constant * bundle)).to eq([3, 6])
      expect(firsts(2 * bundle)).to eq([2, 4])
      expect(firsts(bundle - 1)).to eq([0, 1])
    end

    it 'uses a single-channel node for every channel' do
      expect(firsts(bundle + 5.constant)).to eq([6, 7])
    end

    it 'rejects mismatched channel counts' do
      three = MB::Sound.channels(1.constant, 2.constant, 3.constant)
      expect { three + bundle }.to raise_error(ArgumentError, /Can't combine 3 and 2 channels/)
    end
  end

  describe 'per-channel arguments' do
    it 'turns a single-channel node into a bundle with channels(...) values' do
      result = 1.constant * MB::Sound.channels(2, 3)
      expect(result.channel_count).to eq(2)
      expect(firsts(result)).to eq([2, 3])
    end

    it 'accepts per-channel keyword arguments and Durations' do
      result = 1.constant.delay(seconds: MB::Sound.channels(0.001, 0.002), smoothing: false)
      expect(result.outputs.map { |o| o.base_filter.delay_samples }).to eq([48, 96])

      tempo = 1.constant.delay(MB::Sound.channels(1.n16, 1.n8))
      expect(tempo.channel_count).to eq(2)
    end

    it 'spreads values evenly across channels' do
      result = MB::Sound.channels(0.constant, 0.constant, 0.constant) + MB::Sound.spread(0..1)
      expect(firsts(result)).to eq([0, 0.5, 1])
    end

    it 'requires a multichannel signal for spread' do
      expect { 1.constant + MB::Sound.spread(0..1) }.to raise_error(ArgumentError, /spread.*multichannel/)
    end

    it 'gives each channel its own copy of a filter object' do
      result = 1.constant.stereo.filter(150.hz.highpass(quality: 4))
      filters = result.outputs.map(&:base_filter)
      expect(filters.map(&:object_id).uniq.length).to eq(2)
      expect(filters[0].class).to eq(filters[1].class)
    end
  end

  describe '.refresh!' do
    it 'adds per-channel versions of methods from modules included later' do
      mod = Module.new do
        def self.name
          'MB::Sound::GraphNode::SpecExampleMethods'
        end

        def spec_double
          self * 2
        end
      end
      MB::Sound::GraphNode.include(mod)

      expect(firsts(bundle.spec_double)).to eq([2, 4])
    end
  end
end
