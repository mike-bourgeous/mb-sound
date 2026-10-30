require_relative '../../../../support/ui_helpers'

# The render thread's side of the terminal UI: Session#ui_feed, snapshots
# published only when the painter took the last one, CPU per part, master
# meters against Loudness::Analyzer, the scope ring, and the slow Poll.
RSpec.describe(MB::Sound::UI::Feed, :aggregate_failures) do
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: 800) }
  let(:session) { MB::Sound::Session.new(output: output, realtime: false, master_gain: 1.0) }
  let(:feed) { described_class.new }

  after do
    session.close
    MB::Sound.rewind
  end

  # ux-fix-1 item 18: TRACKS showed a kept snapshot's old clip names
  it "gives screens the latest Poll's tracks even on a kept snapshot" do
    screen = Class.new { include MB::Sound::UI::Follow; def initialize(feed) = (@feed = feed; @source = nil; @attached = true; @last = nil) }.new(feed)
    session.ui_feed = feed
    session.process_buffer
    first = screen.send(:snapshot)
    track = MB::Sound::UI::TrackInfo.new(name: :bass, q: '1', clip: 'roll', armed: false)
    feed.slow = MB::Sound::UI::Slow.empty.with(tracks: [track].freeze)
    kept = screen.send(:snapshot) # (no buffer since: the same snapshot)
    expect(kept.seq).to eq(first.seq)
    expect(kept.tracks.map(&:clip)).to eq(['roll'])
  end

  it 'publishes a snapshot after a buffer only when the last one was taken' do
    session.ui_feed = feed
    session.add(220.hz.triangle.at(-12.db), name: :tri)
    session.process_buffer
    first = feed.take
    expect(first).to be_a(MB::Sound::UI::Snapshot)
    expect(first).to be_frozen
    expect(first.seq).to eq(1)

    # Taken: the next buffer publishes, then nothing until it is taken
    3.times { session.process_buffer }
    second = feed.latest
    expect(feed.published).to eq(2)
    expect(second.seq).to eq(2)
    expect(second.frame).to eq(800 * 2)
    expect(feed.take).to equal(second)

    session.process_buffer
    third = feed.take
    expect(third.seq).to eq(3)
    expect(third.frame).to eq(800 * 5)
    second = third
    expect(second.players.map(&:name)).to eq([:tri])
    expect(second.players[0].state).to eq(:playing)
    expect(second.players[0].load).to be > 0
    expect(second.playing).to eq(true)
    expect(second.stamp).to eq('1:1')
  end

  it 'reports each part: players by state, buses, and the master chain' do
    session.ui_feed = feed
    session.master { |mix| mix.softclip }
    session.bus(:verb) { |sig| sig * 0.5 }
    session.add(110.hz.saw.at(-20.db), name: :saw)
    session.route(:saw, send: { verb: -6.db })
    feed.take
    4.times { session.process_buffer }
    kinds = feed.take.parts.to_h { |p| [p.name, p.kind] }
    expect(kinds).to eq(saw: :player, verb: :bus, master: :master)
  end

  it 'counts graph CPU time only while a feed is attached' do
    session.add(220.hz.sine, name: :s)
    3.times { session.process_buffer }
    expect(session.ui_parts.first.cpu).to eq(0.0)

    session.ui_feed = feed
    session.process_buffer # publishes (reading the counts)
    session.process_buffer # counts, not taken
    expect(session.ui_parts.first.cpu).to be > 0
    expect(session.ui_parts.first.cpu).to eq(0.0) # reset by reading
  end

  it 'meters the master: short-term loudness and true peak like Loudness::Analyzer' do
    feed.needs = [:meters]
    session.ui_feed = feed
    session.add(997.hz.sine.at(-20.db), name: :s)

    analyzer = MB::Sound::Loudness::Analyzer.new(channels: 2)
    session.add_tap { |mix| analyzer.process(mix) }
    # 4 s, so the 3 s window is full; the snapshot taken before the last
    # buffer is published by it
    239.times { session.process_buffer }
    feed.take
    session.process_buffer
    m = feed.take.master
    expect(m.peak.map { |p| p.round(3) }).to eq([-20.0, -20.0])
    expect(m.true_peak).to be_within(0.01).of(analyzer.true_peak)
    expect(m.lufs_s).to be_within(0.05).of(analyzer.short_term)
  end

  describe MB::Sound::UI::MasterMeter do
    it 'measures peaks and RMS per interval' do
      m = described_class.new(2, 48000)
      loud = Numo::SFloat.new(800).seq.map { |i| 0.5 * Math.sin(i * 0.1) }
      quiet = loud * 0.01
      m.process([loud, quiet])
      m.process([quiet, quiet])
      l = m.take
      expect(l.peak[0]).to be_within(1e-6).of(loud.abs.max.to_db)
      expect(l.peak[1]).to be_within(1e-6).of(quiet.abs.max.to_db)
      both = loud.concatenate(quiet)
      expect(l.rms[0]).to be_within(1e-6).of(Math.sqrt((Numo::DFloat.cast(both)**2).mean).to_db)

      # A new interval forgets the loud buffer
      m.process([quiet, quiet])
      expect(m.take.peak[0]).to be_within(1e-6).of(quiet.abs.max.to_db)
    end

    it 'reads the same with the allocation-free kernel as with Numo (alloc-1)' do
      rng = Random.new(11)
      sizes = [128, 128, 800, 37, 512, 128, 2048, 4800, 128, 6000]
      bufs = sizes.map { |n| Array.new(2) { Numo::SFloat.new(n).rand(-1, 1) * rng.rand } }
      results = [true, false, :mixed].map do |mode|
        m = described_class.new(2, 48000)
        bufs.each_with_index.map { |b, i|
          MB::Sound::Kernels.set(meter_block: (mode == :mixed ? i.odd? : mode) ? :c : :ruby)
          m.process(b)
          m.take.to_h
        }
      end
      expect(results[0]).to eq(results[1])
      expect(results[2]).to eq(results[1])
      expect(results[1].last[:lufs_s]).to be_finite
    end

    it 'allocates only a few objects per buffer' do
      m = described_class.new(2, 48000)
      b = [Numo::SFloat.new(128).rand(-1, 1), Numo::SFloat.new(128).rand(-1, 1)]
      20.times { m.process(b) }
      a0 = GC.stat(:total_allocated_objects)
      100.times { m.process(b) }
      expect((GC.stat(:total_allocated_objects) - a0) / 100.0).to be < 12
    end

    it 'reads -inf for silence' do
      m = described_class.new(1, 48000)
      m.process([Numo::SFloat.zeros(4800)])
      l = m.take
      expect([l.peak, l.rms, l.true_peak, l.lufs_s].flatten).to all(eq(-Float::INFINITY))
    end
  end

  it 'keeps the latest samples for scope panes' do
    feed.needs = [:scope]
    session.ui_feed = feed
    session.add(0.25.constant, name: :dc)
    collected = []
    session.add_tap { |mix| collected << mix[0].dup }
    2.times { session.process_buffer(500) }
    feed.take
    session.process_buffer(500)
    scope = feed.take.scope
    expect(scope.length).to eq(2)
    expect(scope[0].length).to eq(described_class::SCOPE_LENGTH)
    expect(scope[0]).to be_frozen
    all = collected.reduce { |a, b| a.concatenate(b) }
    expect(scope[0].to_a).to eq(all[-1024..].to_a)
  end

  it 'leaves meters and the scope out when no pane needs them' do
    session.ui_feed = feed
    session.add(220.hz.sine, name: :s)
    feed.take
    session.process_buffer
    s = feed.take
    expect(s.master).to be_nil
    expect(s.scope).to be_nil
  end

  describe MB::Sound::UI::ScopeRing do
    it 'matches the tail of everything written, across wraps' do
      ring = described_class.new(1, 100)
      all = []
      [30, 70, 45, 130, 1, 99].each_with_index do |n, k|
        buf = Numo::SFloat.new(n).seq(k * 1000)
        all.concat(buf.to_a)
        ring.write([buf])
        tail = all.last(100)
        expect(ring.to_a[0].to_a.last(tail.length)).to eq(tail)
      end
    end
  end

  describe MB::Sound::UI::Poll do
    it 'gathers tracks, scenes, queued changes, recordings, the form, and knobs without the render lock' do
      session.knob(:cut, 800, range: 100..8000, curve: :exp, unit: 'Hz')
      arr = session.arrangement
      clip = MB::Sound.seq(MB::Sound::A2, MB::Sound::C3).n4.loop.named(:bass_a)
      arr.track(:bass) { |c| c.tone.saw.at(-20.db) * c.amp_env }
      arr.scene(:drop, bass: clip)
      MB::Sound::Session.with_context(session: session) { arr.go(:drop, in: 1) }

      expect(session).not_to receive(:players)
      expect(session).not_to receive(:clock)
      expect(session).not_to receive(:strip_info)
      slow, refs = described_class.new(session).call
      expect(slow).to be_frozen
      expect(slow.tracks.map(&:name)).to eq([:bass])
      expect(slow.scenes).to eq([:drop])
      expect(slow.queued.map { |q| [q.kind, q.subject] }).to eq([[:scene, :drop], [:bg, :bass]])
      expect(slow.knob_specs.keys).to eq([:cut])
      expect(refs.map(&:first)).to eq([:cut])

      121.times { session.process_buffer } # past bar 2
      slow, = described_class.new(session).call
      expect(slow.queued).to eq([])
      expect(slow.scene).to eq(:drop)
      expect(slow.tracks[0].clip).to eq('bass_a')
    end
  end
end
