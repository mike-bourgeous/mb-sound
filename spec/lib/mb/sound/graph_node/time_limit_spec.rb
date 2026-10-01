RSpec.describe(MB::Sound::GraphNode::TimeLimit, :aggregate_failures) do
  describe 'GraphNode#until' do
    it 'passes the source through for its length, then ends' do
      node = 1.constant.until(10.0 / 48000)
      expect(node).to be_a(described_class)
      expect(node.sample(6)).to eq(Numo::SFloat.ones(6))
      expect(node.sample(6)).to eq(Numo::SFloat.ones(4))
      expect(node.sample(6)).to eq(nil)
    end

    it 'rounds the length to the nearest sample' do
      node = 1.constant.until(0.6 / 48000)
      expect(node.sample(30)).to eq(Numo::SFloat.ones(1))
      expect(node.sample(30)).to eq(nil)
    end

    it 'ends sooner if the source does' do
      node = 1.constant.until(3.0 / 48000).until(1)
      expect(node.sample(10)).to eq(Numo::SFloat.ones(3))
      expect(node.sample(10)).to eq(nil)
    end

    it 'counts at the sample rate, keeping elapsed seconds when it changes' do
      node = 1.constant.until(1).at_rate(100)
      expect(node.sample_rate).to eq(100)
      expect(node.sample(50).length).to eq(50)
      node.at_rate(200)
      expect(node.sample(1000).length).to eq(100)
      expect(node.sample(1)).to eq(nil)
    end

    it 'ends sums and products' do
      graph = 100.hz.ramp.until(0.1) * 0.5
      total = 0
      while (buf = graph.sample(800))
        total += buf.length
      end
      expect(total).to eq(4800)
    end

    it 'runs per channel on bundles' do
      bundle = MB::Sound.stereo(1.constant, 2.constant).until(2.0 / 48000)
      expect(bundle).to be_a(MB::Sound::GraphNode::Channels)
      expect(bundle.map { |c| c.sample(5).to_a }.to_a).to eq([[1, 1], [2, 2]])
    end

    context 'with a musical Duration' do
      let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

      # Samples +node+ in +size+ buffers until it ends, returning the total.
      def total_length(node, size = 1000)
        total = 0
        while (buf = node.sample(size))
          total += buf.length
        end
        total
      end

      it 'counts the length at the tempo' do
        node = 1.constant.until(1.bar).start_at(0, transport: transport)
        expect(node).to be_musical
        expect(total_length(node)).to eq(96000) # 2 s at 120 BPM
      end

      it 'follows tempo changes during the length' do
        node = 1.constant.until(1.bar).start_at(0, transport: transport)
        expect(node.sample(48000).length).to eq(48000) # half a bar at 120 BPM
        transport.bpm = 60
        expect(total_length(node)).to eq(96000) # the other half bar at 60 BPM
      end

      it 'counts from its first sample, so and_then plays the lengths in turn' do
        graph = 1.constant.until(1.beat).and_then(2.constant.until(1.beat))
        graph.graph.grep(described_class).each { |n| n.start_at(0, transport: transport) }
        data = graph.multi_sample(1000, 60)
        expect(data[0...24000].to_a.uniq).to eq([1])
        expect(data[24000...48000].to_a.uniq).to eq([2])
        expect(data.length).to eq(48000)
      end

      it 'does not count while the timeline is paused' do
        node = 1.constant.until(1.beat).start_at(0, transport: transport)
        node.pause_timeline
        expect(node.sample(48000).length).to eq(48000)
        node.start_at(0)
        expect(total_length(node)).to eq(24000)
      end

      it 'ends a background player on the exact sample at the render tempo' do
        filename = tmp_path('until.flac')
        MB::Sound.render(filename, bpm: 90, gain: 1) { MB::Sound.bg(1.constant.until(2.bars), fade: 0) }
        data = MB::Sound.read(filename)[0]
        sound = (0...data.length).select { |i| data[i] > 0.5 }
        expect(sound.first).to eq(0)
        expect(sound.last + 1).to eq(256000) # 2 bars at 90 BPM = 5.33 s
      ensure
        MB::Sound.rewind
      end
    end

    it 'rejects negative and non-numeric lengths' do
      expect { 1.constant.until(-1) }.to raise_error(ArgumentError, /seconds/)
      expect { 1.constant.until('3') }.to raise_error(ArgumentError, /seconds/)
      expect { 1.constant.until(-1.bar) }.to raise_error(ArgumentError, /Duration/)
    end
  end
end
