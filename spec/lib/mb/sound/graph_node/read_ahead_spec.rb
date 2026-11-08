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
        zero = ReadAheadSweep::ZERO_LATENCY.include?(chain)
        twin = ReadAheadSweep::TWINS.fetch(chain, chain)
        it "#{chain} as a #{context} plays the track's output#{" (as #{twin})" if twin != chain}, #{zero ? 'not late' : 'its declared latency later'}, at any buffer size" do
          expected = track_for.(twin)
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
          if zero
            expect(latencies[0]).to eq(0)
          else
            expect(latencies[0]).to be > 0
          end
        end
      end
    end

    it 'builds every node class that reads ahead' do
      built = ReadAheadSweep::CHAINS.keys.flat_map { |c| ReadAheadSweep.classes(c) }.uniq
      missing = ReadAheadSweep.read_ahead_classes - built
      expect(missing).to be_empty, "add a chain building #{missing.map(&:name).join(', ')} to ReadAheadSweep::CHAINS"
    end
  end

  it 'gives :min_phase chains and chains given no mode latency 0' do
    ReadAheadSweep::ZERO_LATENCY.each do |chain|
      _, latency = ReadAheadSweep.render(chain, :bus, [800], frames: 1600)
      expect(latency).to eq(0), chain.to_s
    end
  end

  describe 'live and offline Sessions' do
    let(:sessions) { [] }
    after { sessions.each(&:close) }

    def session(realtime, output: nil, **opts)
      out = output || MB::Sound::NullOutput.new(channels: 1, sleep: realtime ? :virtual : false)
      MB::Sound::Session.new(output: out, channels: 1, realtime: realtime, transport: MB::Sound::Sequence::Transport.new(bpm: 120), **opts).tap { |s| sessions << s }
    end

    def modes(nodes)
      nodes.flat_map { |n| [n, *n.graph] }.uniq.grep(MB::Sound::GraphNode::Resample).map(&:mode)
    end

    { 'live' => true, 'offline (renders)' => false }.each do |label, realtime|
      it "#{label}: switch bus and master chains' resamplers given no mode to :min_phase, so the chains are not late" do
        s = session(realtime)
        s.bus(:b) { |sig| sig.resample(96000).lp4(9000).resample(48000) }
        s.master { |mix| mix.resample(96000).resample(48000, mode: :libsamplerate_fastest) }
        bus = s.instance_variable_get(:@buses)[:b].chains.last
        master = s.instance_variable_get(:@master_chains).last
        expect(modes(bus.nodes)).to eq([:min_phase, :min_phase])
        expect(bus.latency).to eq(0)
        expect(modes(master.nodes)).to contain_exactly(:min_phase, :libsamplerate_fastest) # (a given mode stays)
        expect(master.latency).to be > 0
      end

      it "#{label}: switch graphs reading a bus tap, and leave resamplers that do not reach it alone" do
        s = session(realtime)
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
    end

    it 'render a bus chain as the same samples live and offline' do
      chain = ->(sig) { sig.resample(96000).filter(:lowpass, cutoff: 20000.0, quality: 0.7).resample(48000) }
      outs = [true, false].map { |realtime|
        written = []
        out = MB::Sound::NullOutput.new(channels: 1, sleep: realtime ? :virtual : false)
        out.define_singleton_method(:write) { |data| written << data[0].dup; super(data) }
        s = session(realtime, output: out, master_gain: 1, buffer_size: 800)
        s.bus(:b) { |sig| chain.(sig) }
        expect(s.instance_variable_get(:@buses)[:b].chains.last.latency).to eq(0)
        s.add(MB::Sound::ArrayInput.new(data: [ReadAheadSweep.signal * 0.2], sample_rate: 48000), name: :t, to: :b)
        if realtime
          out.consume(0.5)
        else
          30.times { s.process_buffer(800) }
        end
        s.close
        c = SpecBuffers.join(written)
        # (a live player may start on a later buffer: align on the first
        # sound; quiet enough for the live safety limiter to stay out)
        c[(c.abs > 0).where[0]..].dup
      }
      n = 12000
      expect(outs.map(&:length)).to all(be >= n)
      expect(outs[0][0...n]).to eq(outs[1][0...n])
    end
  end

  describe 'a tap read through a BufferAdapter (fix-batch22)' do
    # (the batch 22 SLOW=1 suite: with_buffer(300) after a tap at 128,
    # 801, and 7-frame buffers read nothing in spans its block covered,
    # so those spans never reached the tap's history, and its next block
    # read them as silence: -0.0 dB from the track)
    it 'keeps the spans its graph skips, at buffers smaller than the block' do
      expected = ReadAheadSweep.render(:buffer_adapter, :track, [800])[0]
      out, latency = ReadAheadSweep.render(:buffer_adapter, :tap, [128, 801, 7])
      expect(latency).to eq(299)
      shifted = out[latency..]
      expect(residual_db(shifted, expected[0...shifted.length])).to be < -80
    end

    it 'stops keeping spans once its graph stops reading' do
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
      s = MB::Sound::Session.new(output: out, channels: 1, buffer_size: 100, realtime: false, raise_errors: true,
                                 transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      tap = MB::Sound::GraphNode::BusTap.new(:src, channels: 1)
      s.route(:src, trigger: true)
      s.add(0.5.constant, name: :src)
      s.add(tap.outputs[0].with_buffer(300), name: :rd)
      5.times { s.process_buffer(100) }
      expect(tap.keeping).to eq(true)
      s.remove(:rd, fade: 0)
      10.times { s.process_buffer(100) }
      expect(tap.keeping).to eq(false)
      expect(s.instance_variable_get(:@ahead_taps)).to be_empty
    ensure
      s&.close
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
    # (given a mode, so the pair still reads ahead: its latency, since
    # resample-render-minphase only when a mode is given)
    [800, 367].each do |size|
      it "delays a click by the chain's latency only, playing it once, at #{size}-frame buffers" do
        click = Numo::SFloat.zeros(48000)
        click[100] = 1.0
        click[24000] = 0.5
        out = MB::Sound::NullOutput.new(channels: 2, sleep: false)
        s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                                   channels: 2, buffer_size: size, realtime: false, raise_errors: true)
        s.bus(:bus1) { |sig| sig.resample(96000, mode: :libsamplerate_best).resample(48000, mode: :libsamplerate_best) }
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

    it 'given no mode, plays the click once and not late (:min_phase, live and in renders)' do
      click = Numo::SFloat.zeros(48000)
      click[100] = 1.0
      click[24000] = 0.5
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
      s = MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                                 channels: 1, buffer_size: 367, realtime: false, raise_errors: true)
      s.bus(:bus1) { |sig| sig.resample(96000).resample(48000) }
      s.add(MB::Sound::ArrayInput.new(data: [click], sample_rate: 48000), name: :clk, to: :bus1)
      expect(s.instance_variable_get(:@buses)[:bus1].chains.last.latency).to eq(0)
      expect(s.bus_info[:bus1]).not_to include('frames late')

      bufs = []
      (48000 / 367 + 1).times { bufs << s.process_buffer(367)[0].dup }
      s.close
      c = SpecBuffers.join(bufs)
      hits = (c.abs > 0.05).where.to_a.chunk_while { |a, b| b <= a + 8 }.map(&:first)
      expect(hits.length).to eq(2)
      peaks = [c[0...12000].abs.max_index, c[12000..].abs.max_index + 12000]
      expect(peaks[0]).to be_between(100, 116)
      expect(peaks[1] - peaks[0]).to eq(23900)
    end
  end
end
