RSpec.describe(MB::Sound::Session::Changes) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  # Renders +frames+ frames in +size+-frame buffers and returns the mix.
  def run(frames, size = 800)
    out = []
    left = frames
    while left > 0
      n = [size, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    SpecBuffers.join(out)
  end

  # Returns [sample index, value] for each change in +data+.
  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v] }
  end

  describe 'the change queue' do
    it 'lands several queued replacements of one player, each on its sample' do
      session.add(1.constant, name: :x)
      session.add(3.constant, name: :x, start_time: 2r, fade: 0)
      session.add(2.constant, name: :x, start_time: 1r, fade: 0)
      expect(session.queued(:x).map(&:kind)).to eq([:bg, :bg])

      expect(changes(run(96000 * 3))).to eq([[0, 1], [96000, 2], [192000, 3]])
    end

    it 'lands several queued swaps of one player (one pending swap per clip source used to win)' do
      a = MB::Sound.seq(MB::Sound::C3).n1.loop
      b = MB::Sound.seq(MB::Sound::D3).n1.loop
      c = MB::Sound.seq(MB::Sound::E3).n1.loop
      session.add(a.number, name: :n)
      run(800)

      session.swap(:n, b, start_time: 2r)
      session.swap(:n, c) # next bar, before the first
      expect(session.queued(:n).map { |e| e.lands.pos }).to eq([1r, 2r])

      data = run(96000 * 3)
      expect(changes(data)).to eq([[0, 48], [96000 - 800, 52], [192000 - 800, 50]])
    end

    it 'applies changes landing at the same time in the order they were made' do
      session.add(1.constant, name: :x)
      session.add(2.constant, name: :x, start_time: 1r, fade: 0)
      session.remove(:x, fade: 0, time: 1r)
      data = run(96000 * 2)
      expect(changes(data)).to eq([[0, 1], [96000, 0]])
    end

    # (arm_state_spec's random walk, seed 11181: a scene queued for 2:1,
    # then a seek to bar 2 and another scene landing now; the earlier
    # scene's swap then failed on a stopped player)
    it 'lands a queued change whose time has come between buffers before a change made now' do
      MB::Sound::Session.with_context(session: session) { MB::Sound.bg(:y, MB::Sound.seq(MB::Sound::C4).n4.loop) }
      run(800)
      MB::Sound::Session.with_context(session: session) { MB::Sound.swap(:y, MB::Sound.seq(MB::Sound::E4).n4.loop) }
      run(96000 - 800) # (ends on the bar line: the swap is due, not yet landed)
      expect(session.queued.map(&:kind)).to eq([:swap])
      MB::Sound::Session.with_context(session: session) { MB::Sound.stop(:y, fade: 0) }
      expect(session.queued).to eq([])
      expect(session.journal.changes.last(2).map { |e| [e.kind, e.status, e.lands.pos] }).to eq([[:swap, :landed, 1r], [:stop, :landed, 1r]])
      expect { run(1600) }.not_to raise_error
    end

    it 'lands a queued change due after a seek that lands now before the next change made now' do
      MB::Sound::Session.with_context(session: session) { MB::Sound.bg(:y, MB::Sound.seq(MB::Sound::C4).n4.loop) }
      run(800)
      MB::Sound::Session.with_context(session: session) { MB::Sound.swap(:y, MB::Sound.seq(MB::Sound::E4).n4.loop) }
      session.seek(2)
      MB::Sound::Session.with_context(session: session) { MB::Sound.stop(:y, fade: 0) }
      expect(session.journal.changes.last(3).map { |e| [e.kind, e.status] }).to eq([[:swap, :landed], [:seek, :landed], [:stop, :landed]]) # (issue order)
      expect { run(1600) }.not_to raise_error
    end

    it 'lets a queued graph start after a queued stop' do
      session.add(1.constant, name: :x)
      session.remove(:x, fade: 0, time: 1r)
      session.add(2.constant, name: :x, start_time: 2r, fade: 0)
      expect(changes(run(96000 * 3))).to eq([[0, 1], [96000, 0], [192000, 2]])
    end

    it 'cancels graphs waiting to start when stopped now' do
      session.add(1.constant, name: :x)
      session.add(2.constant, name: :y, start_time: 1r)
      expect(session.players.keys).to eq([:x, :y])
      expect(session.players[:y]).to match(/starts at bar 2/)

      expect(session.remove(:y, fade: 0)).to eq([:y])
      expect(session.journal.changes.map { |e| [e.kind, e.subject, e.status] }).to include([:bg, :y, :cancelled])
      expect(changes(run(96000 * 2))).to eq([[0, 1]])
    end

    it 'keeps the timeline moving while a graph waits in the queue' do
      session.add(1.constant, name: :x, start_time: 1/2r)
      expect(session.idle?).to eq(false)
      expect(changes(run(96000))).to eq([[0, 0], [48000, 1]])
    end

    it 'gives the next free number to an unnamed graph while another waits' do
      session.add(1.constant)
      expect(session.add(2.constant, start_time: 1r)).to eq(2)
      expect(session.add(3.constant, start_time: 1r)).to eq(3)
    end
  end

  describe 'the journal' do
    it 'records when changes were issued and exactly when they land' do
      session.add(1.constant, name: :x)
      run(1000)
      session.add(2.constant, name: :x, at: :bar)

      entry = session.journal.changes.last
      expect(entry).to have_attributes(kind: :bg, subject: :x, status: :queued, source: :console)
      expect(entry.issued.pos).to eq(transport.position)
      expect(entry.issued.frame).to eq(1000)
      expect(entry.lands.pos).to eq(1r)
      expect(entry.lands.frame).to be_nil
      expect(entry.to_s).to eq('bg :x lands 2:1 (queued)')

      run(96000)
      landed = session.journal[entry.seq]
      expect(landed.status).to eq(:landed)
      expect(landed.lands.frame).to eq(96000)
      expect(landed.commits.frame).to eq(95400) # the start of the buffer holding the time (buffers start at 1000 + 800n)
      expect(landed.to_s).to eq('bg :x landed 2:1')
      expect(session.journal.entries.count { |e| e.seq == entry.seq }).to eq(2)
    end

    it 'stamps changes that land now with the next frame and position' do
      session.add(1.constant, name: :x)
      run(1600)
      session.mute(:x)
      entry = session.journal.changes.last
      expect(entry.status).to eq(:landed)
      expect(entry.lands.frame).to eq(1600)
      expect(entry.lands.pos).to eq(transport.position)
    end

    it 'stamps landing frames that never reset when the timeline seeks' do
      session.add(1.constant, name: :x)
      run(1600)
      transport.seek(0)
      run(800)
      session.mute(:x)
      expect(session.journal.changes.last.lands).to have_attributes(frame: 2400, pos: 800 / 96000r)
    end

    it 'calls subscribers with new entries' do
      seen = []
      session.journal.subscribe { |e| seen << [e.kind, e.status] }
      session.add(1.constant, name: :x)
      session.add(2.constant, name: :x, at: :bar)
      run(96000)
      session.journal.changes # folds notes from the render thread
      expect(seen).to eq([[:bg, :queued], [:bg, :landed], [:bg, :queued], [:bg, :landed]])
    end

    it 'records failed changes' do
      session.add(1.constant, name: :x)
      session.instance_variable_set(:@raise_errors, false)
      session.change(:test, :x, 1/2r) { raise 'nope' }
      expect { run(96000) }.to output(/test :x at 1:3 failed: RuntimeError: nope/).to_stderr
      expect(session.journal.changes.last).to have_attributes(status: :failed, data: { error: 'nope' })
    end

    it 'prints stamps as bar:beat' do
      expect(session.stamp(0).to_s).to eq('1:1')
      expect(session.stamp(13/4r).to_s).to eq('4:2')
      expect(session.stamp(13/4r + 1/8r).to_s).to eq('4:2.5')
    end

    it 'keeps a per-buffer transport record' do
      session.add(1.constant)
      run(800)
      expect(session.transport_record).to eq(frame: 800, pos: 800 / 96000r, bpm: 120, bar_length: 1, playing: true)
    end
  end

  describe 'launch points inside scheduled blocks' do
    it 'count from the block time, not from where the scheduler runs it (half a bar early)' do
      MB::Sound::Session.with_context(session: session) do
        MB::Sound.bg(:bed, 0.constant)
        MB::Sound.at_bar(5) do
          MB::Sound.bg(:beat, 1.constant, at: :beat)
          MB::Sound.bg(:bar, 2.constant, at: :bar)
          MB::Sound.bg(:two, 4.constant, on: 2)
          MB::Sound.bg(:none, 8.constant)
        end
      end

      data = run(96000 * 5)
      expect(changes(data)).to eq([[0, 0], [96000 * 4, 15]])
    end
  end
end
