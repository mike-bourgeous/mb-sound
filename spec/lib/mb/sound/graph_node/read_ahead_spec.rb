require_relative '../../../../support/read_ahead_sweep'

RSpec.describe(MB::Sound::GraphNode::ReadAhead) do
  # Relative error of +a+ against +b+: the largest difference over +b+'s peak
  def residual_db(a, b)
    peak = b.abs.max
    diff = (a - b).abs.max
    diff == 0 ? -Float::INFINITY : 20 * Math.log10(diff / peak)
  end

  describe 'sweep: chains that read ahead, on a track and fed by the Session' do
    tracks = {}
    track_for = ->(chain) { tracks[chain] ||= ReadAheadSweep.render(chain, :track, [800])[0] }

    ReadAheadSweep::CHAINS.each_key do |chain|
      (ReadAheadSweep::CONTEXTS - [:track]).each do |context|
        it "#{chain} as a #{context} plays the track's output, its declared latency later, at any buffer size" do
          expected = track_for.(chain)
          expect(expected.abs.max).to be > 0.1

          latencies = []
          [[800], *slow_tier([[367], [128, 801, 7]])].each do |sizes|
            out, latency = ReadAheadSweep.render(chain, context, sizes)
            latencies << latency
            expect(out.length).to eq(expected.length)
            expect(out[0...latency].abs.max).to eq(0) if latency > 0
            shifted = out[latency..]
            db = residual_db(shifted, expected[0...shifted.length])
            expect(db).to be < -80, "#{chain} #{context} at #{sizes}: #{db.round(1)} dB from the track #{latency} frames later"
          end
          expect(latencies.uniq.length).to eq(1)
        end
      end
    end

    it 'builds every node class that reads ahead' do
      built = ReadAheadSweep::CHAINS.keys.flat_map { |c| ReadAheadSweep.classes(c) }.uniq
      missing = ReadAheadSweep.read_ahead_classes - built
      expect(missing).to be_empty, "add a chain building #{missing.map(&:name).join(', ')} to ReadAheadSweep::CHAINS"
    end
  end

  it 'gives :min_phase chains latency 0' do
    ReadAheadSweep::CHAINS.each_key.grep(/min_phase/).each do |chain|
      _, latency = ReadAheadSweep.render(chain, :bus, [800], frames: 1600)
      expect(latency).to eq(0), chain.to_s
    end
  end

  describe 'live Sessions' do
    let(:sessions) { [] }
    after { sessions.each(&:close) }

    def session(realtime)
      out = MB::Sound::NullOutput.new(channels: 1, sleep: realtime ? :virtual : false)
      MB::Sound::Session.new(output: out, channels: 1, realtime: realtime, transport: MB::Sound::Sequence::Transport.new(bpm: 120)).tap { |s| sessions << s }
    end

    def modes(nodes)
      nodes.flat_map { |n| [n, *n.graph] }.uniq.grep(MB::Sound::GraphNode::Resample).map(&:mode)
    end

    it 'switch bus and master chains\' resamplers given no mode to :min_phase, so the chains are not late' do
      s = session(true)
      s.bus(:b) { |sig| sig.resample(96000).lp4(9000).resample(48000) }
      s.master { |mix| mix.resample(96000).resample(48000, mode: :libsamplerate_fastest) }
      bus = s.instance_variable_get(:@buses)[:b].chains.last
      master = s.instance_variable_get(:@master_chains).last
      expect(modes(bus.nodes)).to eq([:min_phase, :min_phase])
      expect(bus.latency).to eq(0)
      expect(modes(master.nodes)).to contain_exactly(:min_phase, :libsamplerate_fastest) # (a given mode stays)
      expect(master.latency).to be > 0
    end

    it 'switch graphs reading a bus tap, and leave resamplers that do not reach it alone' do
      s = session(true)
      tap = MB::Sound::GraphNode::BusTap.new(:src, channels: 1)
      other = 3.hz.sine.resample(96000).resample(48000)
      graph = tap.outputs[0].resample(96000).resample(48000) + other
      s.route(:src, trigger: true)
      s.add(0.constant, name: :src)
      s.add(graph, name: :rd)
      others = [other, *other.graph].uniq.grep(MB::Sound::GraphNode::Resample)
      reaching = [graph, *graph.graph].uniq.grep(MB::Sound::GraphNode::Resample).reject { |r| others.any? { |o| o.equal?(r) } }
      expect(reaching.map(&:mode)).to eq([:min_phase, :min_phase])
      expect(others.map(&:mode)).to eq([:libsamplerate_best, :libsamplerate_best])
      expect(tap.read_ahead).to eq(0)
    end

    it 'leave offline Sessions (renders) on the default mode' do
      s = session(false)
      s.bus(:b) { |sig| sig.resample(96000).resample(48000) }
      bus = s.instance_variable_get(:@buses)[:b].chains.last
      expect(modes(bus.nodes)).to eq([:libsamplerate_best, :libsamplerate_best])
      expect(bus.latency).to eq(315)
    end
  end

  describe '.frames' do
    let(:src) { MB::Sound::GraphNode::MixSource.new(channels: 2) }

    it 'is 0 for chains that read in step' do
      nodes = src.outputs.map { |c| c.lp4(900) * 0.5 }
      expect(MB::Sound::GraphNode::ReadAhead.frames(nodes, src, 48000)).to eq(0)
    end

    it 'adds read-ahead along a path through rate changes, and takes the longest path' do
      up = MB::Sound::GraphNode::Resample.new(upstream: src.outputs[0], sample_rate: 96000)
      down = up.resample(48000)
      expected = up.read_ahead + (down.read_ahead / 2.0).ceil
      expect(MB::Sound::GraphNode::ReadAhead.frames([down, src.outputs[1]], src, 48000)).to be_between(expected - 1, expected)
    end

    it 'ignores read-ahead on paths that do not reach the source' do
      nodes = [src.outputs[0] + 3.hz.sine.resample(96000).resample(48000)]
      expect(MB::Sound::GraphNode::ReadAhead.frames(nodes, src, 48000)).to eq(0)
    end
  end

  describe 'a resample pair in a bus (the Nightfall drum bus, 2026-11-08)' do
    [800, 367].each do |size|
      it "delays a click by the chain's latency only, playing it once, at #{size}-frame buffers" do
        click = Numo::SFloat.zeros(48000)
        click[100] = 1.0
        click[24000] = 0.5
        out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                                   channels: 2, buffer_size: size, realtime: false, raise_errors: true)
        s.bus(:bus1) { |sig| sig.resample(96000).resample(48000) }
        s.add(MB::Sound::ArrayInput.new(data: [click.dup, click.dup], sample_rate: 48000), name: :clk, to: :bus1)
        latency = s.instance_variable_get(:@buses)[:bus1].chains.last.latency
        expect(latency).to be_between(1, 400)
        expect(s.bus_info[:bus1]).to include("#{latency} frames late")

        bufs = []
        (48000 / size + 1).times { bufs << s.process_buffer(size).map(&:dup) }
        s.close
        bufs.transpose.each do |chan|
          c = SpecBuffers.join(chan)
          hits = (c.abs > 0.05).where.to_a.chunk_while { |a, b| b == a + 1 }.map(&:first)
          expect(hits).to eq([100 + latency, 24000 + latency])
        end
      end
    end
  end
end
