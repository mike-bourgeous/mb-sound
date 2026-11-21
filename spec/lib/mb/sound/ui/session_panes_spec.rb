require_relative '../../../../support/ui_helpers'

# The set's panes (ux-1 r3 items 29 and 32): buses and sends with the
# routing tree, landed changes, the launch lane, clips, MIDI; what Poll
# gathers for them from a Session; meters and scopes delayed to what is
# heard.
RSpec.describe('UI session panes', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  def snap_with(**slow)
    base = ui_fake_snapshot
    base.with(slow: base.slow.with(**slow))
  end

  def draw(name, snap, w = 50, h = 12)
    grid = MB::Term::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, { title_in_rule: true })
    grid.to_text(:none).lines.map(&:rstrip)
  end

  it 'draws buses with their sends as meters and the routing tree from the master' do
    snap = snap_with(
      buses: [ui::BusInfo.new(name: :verb, to: :master, description: 'reverb', asleep: false, muted: false),
              ui::BusInfo.new(name: :drums, to: :master, description: 'bypass', asleep: true, muted: false)].freeze,
      routes: { bass: { to: :master, send: { verb: 0.25 } }, kick: { to: :drums, send: {} } }.freeze
    )
    lines = draw(:buses, snap.with(bus_levels: nil, send_levels: nil))
    text = lines.join("\n")
    expect(lines[0]).to start_with('● verb').and include('→ master', 'reverb')
    expect(text).to include('drums', 'asleep')
    expect(lines[1]).to match(/\A ← bass\s+-12\.0 dB\z/) # (0.25 = -12 dB; no level meter until the feed sends levels)
    expect(lines[3]).to match(/\A ← kick\s+to:\z/) # (routed whole)
    expect(text).to include('routing', 'master', '├─ verb', 'bass (send)', 'kick')
    expect(draw(:buses, snap_with(buses: [].freeze)).first).to start_with('no buses')
  end

  it 'shows track levels set away from unity in the tracks pane (omnibus17)' do
    tracks = [ui::TrackInfo.new(name: :bass, q: '1', clip: 'bass_a', armed: false, level: -6.0),
              ui::TrackInfo.new(name: :pad, q: '1', clip: 'chords', armed: false)].freeze
    text = draw(:tracks, snap_with(tracks: tracks), 40, 4).join("\n")
    expect(text).to match(/bass\s+-6 dB bass_a/)
    expect(text).to match(/pad\s+stopping chords/) # (no level shown at unity)
  end

  # (tuner-fixes-1, the maintainer: "The tracks UI says it has nothing to
  # scroll but at the bottom it says +5 more"; "let me use arrows to
  # highlight tracks and then delete them, or change their volume")
  it 'picks tracks with the arrows, scrolling to them, changes the picked level, stops it, and hides stopped tracks' do
    tracks = (1..9).map { |i| ui::TrackInfo.new(name: :"t#{i}", q: '1', clip: 'c', armed: false, level: i == 3 ? -2.0 : nil) }.freeze
    snap = snap_with(tracks: tracks).with(parts: [].freeze) # (no other players)
    pane = ui.panes.fetch(:tracks)
    state = { title_in_rule: true }
    paint = -> {
      grid = MB::Term::Cells.new(40, 5)
      pane.draw(ui::Canvas.new(grid, 0, 0, 40, 5), snap, state)
      grid.to_text(:none).lines.map(&:rstrip)
    }
    lines = paint.()
    expect(lines.last).to eq('+5 more')
    expect(pane.key_action(:scroll, state, 0)).to include('t1') # (the arrows pick here, not "nothing to scroll")
    6.times { pane.key_action(:pick, state, 1) }
    expect(state[:cursor]).to eq(:t7)
    lines = paint.()
    expect(lines.join("\n")).to include('▸t7')
    expect(lines.last).to eq('3 above, +2 more')
    expect(lines.first).to include('t4')

    state[:cursor] = :t3
    r = pane.key_action(:level, state, -1)
    expect(r).to eq([ui::PaneKeys::Preview[:"t3/level", -3.0.db.to_f, 't3 at -3 dB']]) # (live; its level line when the keys stop)
    r = pane.key_action(:level, state, 0)
    expect(r[0]).to eq(ui::PaneKeys::Commit[:"t3/level"]) # (the gesture's line goes out first)
    expect(r[1]).to eq(ui::PaneKeys::Turn['level :t3, 0.0.db', 't3 at 0 dB'])
    pane.lines_ran(state)
    expect(pane.key_action(:stop_track, state).code).to eq('stop :t3')
    # (d twice: untrack, the cursor on the next track)
    expect(pane.key_action(:untrack, state)).to eq('d again removes t3 from the set (undo brings it back)')
    expect(pane.key_action(:untrack, state).code).to eq('untrack :t3')
    expect(state[:cursor]).to eq(:t4)

    # (all nine are stopped in the fake snapshot: v hides them)
    expect(pane.key_action(:stopped_view, state)).to include('hidden')
    expect(paint.().first).to eq('9 stopped (v shows them)')
  end

  # (knobs-pane-keys-1, the maintainer: "most of the keys just repeat the
  # same level, and there's a pretty long delay between pressing once and
  # the level changing")
  describe 'the tracks pane\'s keys (knobs-pane-keys-1)' do
    let(:pane) { ui.panes.fetch(:tracks) }
    let(:parts) {
      [ui::PartLoad.new(name: :t1, kind: :player, state: :playing, load: 0.0),
       ui::PartLoad.new(name: :t2, kind: :player, state: :playing, load: 0.0, muted: true, soloed: true),
       ui::PartLoad.new(name: :t3, kind: :player, state: :stopping, load: 0.0)].freeze
    }
    let(:snap) {
      tracks = (1..5).map { |i| ui::TrackInfo.new(name: :"t#{i}", q: '1', clip: 'c', armed: false) }.freeze
      snap_with(tracks: tracks, stopped: %i[t4].freeze).with(parts: parts)
    }

    around do |ex|
      @now = 50.0
      ui::Panes::Tracks.clock = -> { @now }
      ex.run
    ensure
      ui::Panes::Tracks.clock = nil
    end

    def paint(state, w: 40, h: 6)
      grid = MB::Term::Cells.new(w, h)
      pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state.merge!(title_in_rule: true))
      grid.to_text(:none).lines.map(&:rstrip)
    end

    # (round 2, the maintainer's 2026-11-21 "yes": a live preview while
    # held and one `level` line on release, as knobs do)
    it 'moves the level live on every repeat of a held arrow, the row following, and commits one level line when the keys stop' do
      pk = ui::PaneKeys
      st = { mode: true }
      paint(st)
      st[:cursor] = :t1
      # (a held key: one key, 0.4 s, then 30 a second; the snapshot never catches up)
      out = [pane.key_action(:level, st, -1)]
      @now += 0.4
      9.times do |i|
        out << pane.key_action(:level, st, -1)
        expect(paint(st).find { |l| l.include?('t1') }).to include("-#{i + 2} dB") # (the row, on the next frame)
        expect(pane.key_tick(st)).to be_nil # (still held: no line)
        @now += 1 / 30.0
      end
      expect(out.map(&:length).uniq).to eq([1])
      expect(out.map { |r| r[0] }).to eq((1..10).map { |i| pk::Preview[:"t1/level", (-i.to_f).db.to_f, "t1 at -#{i} dB"] })
      expect(pane.key_wait(st)).to be_within(1e-9).of(ui::TurnGesture::GAP - 1 / 30.0)
      @now += ui::TurnGesture::GAP
      expect(pane.key_tick(st)).to eq(pk::Commit[:"t1/level"]) # (one line, Session#gesture_line: `level :t1, -10.0.db`)
      pane.lines_ran(st)
      expect(pane.key_tick(st)).to be_nil
      expect(pane.key_wait(st)).to be_nil

      # A tap: one preview, one commit
      @now += 5 # (past the carried level: the snapshot's 0 dB again)
      expect(paint(st).find { |l| l.include?('t1') }).not_to include('dB')
      expect(pane.key_action(:level, st, 1)).to eq([pk::Preview[:"t1/level", 1.0.db.to_f, 't1 at 1 dB']])
      @now += ui::TurnGesture::GAP
      expect(pane.key_tick(st)).to eq(pk::Commit[:"t1/level"])
      pane.lines_ran(st)

      # The +12 dB ceiling (on from the carried level), and 0: one line after the gesture's
      12.times { pane.key_action(:level, st, 1); @now += 0.03 }
      expect(pane.key_action(:level, st, 1)).to eq('t1 at 12 dB (the most a level goes)')
      out = pane.key_action(:level, st, 0)
      expect(out).to eq([pk::Commit[:"t1/level"], pk::Turn['level :t1, 0.0.db', 't1 at 0 dB']])
      pane.lines_ran(st)

      # The latest level line on the pane's last row, in its mode only
      st[:turn_line] = 'level :t1, 0.0.db'
      expect(paint(st).last).to eq('level :t1, 0.0.db')
      expect(paint(st.merge(mode: false)).last).not_to include('level :t1')
    end

    it 'plays or stops the picked track with Space: resume when stopped or stopping, stop when playing' do
      st = { mode: true }
      paint(st)
      st[:cursor] = :t1
      expect(pane.key_action(:play_stop, st)).to eq(ui::PaneKeys::Run['stop :t1', 't1 stopping'])
      st[:cursor] = :t3 # (stopping: it comes back)
      expect(pane.key_action(:play_stop, st).code).to eq('resume :t3')
      st[:cursor] = :t4 # (stopped, kept for resume)
      expect(pane.key_action(:play_stop, st)).to eq(ui::PaneKeys::Run['resume :t4', 't4 resuming (on the next bar)'])
      st[:cursor] = :t5 # (never played)
      expect(pane.key_action(:play_stop, st)).to include('t5 has nothing to resume')
      pane.key_action(:stop_track, st) # (stopped by these keys: resumable before the poll's list has it)
      expect(pane.key_action(:play_stop, st).code).to eq('resume :t5')
      expect(pane.key_action(:play_stop, {})).to start_with('pick a track first')
      km = ui::Panes::Tracks.mode_keymap.entries
      expect(km.find { |b| b.chord == [' ', []] }&.action).to eq(:play_stop)
      expect(km.find { |b| b.chord == ['x', []] }&.action).to eq(:stop_track)
      expect(km.find { |b| b.chord == ['s', []] }&.action).to eq(:solo)
      expect(km.find { |b| b.chord == ['m', []] }&.action).to eq(:mute)
      expect(km.find { |b| b.chord == [' ', []] }.help).to include('NAV Space: the transport')
    end

    it 'solos and mutes the picked track or takes it back, from its flags, and marks them in its row' do
      st = { mode: true }
      lines = paint(st)
      expect(lines.find { |l| l.include?('t2') }).to match(/t2\s+solo muted c/)
      expect(lines.find { |l| l.include?('t1') }).to match(/t1\s+c\z/)
      st[:cursor] = :t1
      expect(pane.key_action(:solo, st)).to eq(ui::PaneKeys::Run['solo :t1', 't1 soloed'])
      expect(pane.key_action(:mute, st)).to eq(ui::PaneKeys::Run['mute :t1', 't1 muted'])
      st[:cursor] = :t2
      expect(pane.key_action(:solo, st)).to eq(ui::PaneKeys::Run['unsolo :t2', 't2 unsoloed'])
      expect(pane.key_action(:mute, st)).to eq(ui::PaneKeys::Run['unmute :t2', 't2 unmuted'])
    end

    it 'says how to reach stopped tracks while v hides them' do
      st = { mode: true, hide_stopped: true }
      paint(st)
      expect(pane.key_action(:pick, st, 1)).to include('v shows stopped tracks')
      expect(pane.key_action(:stop_track, st).note).to include('v shows them')
    end

    describe 'on a screen' do
      after do
        @tiles&.stop
        @term&.close
        @session&.close
        MB::Sound.rewind
      end

      it 'stops a track of a loaded demo with x, plays it again with Space on the next bar, and shows a level key at once' do
        ui::Panes::Tracks.clock = nil
        @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        expect { MB::Sound::Session.with_context(session: @session) { MB::Sound.demo(:night_bus); MB::Sound.go(:groove, on: :now) } }.to output(/night_bus/).to_stdout
        8.times { @session.process_buffer }
        @tiles, @term = ui_tiles(:session, rows: 60, cols: 236, session: @session)
        @tiles.show(:tracks, at: :repl) unless @tiles.tiler.layout.panes.include?(:tracks)
        stop = false
        pump = Thread.new { until stop; @session.process_buffer; sleep 0.004; end }
        expect(@term.wait_for('drums')).to eq(true), @term.text
        @tiles.enter(:tracks)
        st = @tiles.instance_variable_get(:@states)[:tracks]
        expect(wait_until { st[:names]&.include?(:drums) && @tiles.router.mode == :pane }).to eq(true)
        @term.write("\e[B") # (Down picks the first track: drums)
        expect(wait_until { st[:cursor] }).to eq(:drums)
        playing = -> { @session.players.key?(:drums) }
        expect(playing.()).to eq(true)
        @term.type('x')
        expect(wait_until { !playing.() }).to eq(true)
        expect(@term.wait_for(/▸drums\s+stopped/)).to eq(true), @term.lines.grep(/drums/).first.inspect
        @term.write(' ') # (Space: these keys just stopped it, so it comes back even before the poll lists it)
        expect(wait_until { playing.() }).to eq(true), @term.lines.last

        expect(@session.journal.changes.select { |e| e.subject == :drums }.map(&:kind)).to include(:stop, :resume)
        resumed = @session.journal.changes.reverse.find { |e| e.kind == :resume && e.subject == :drums }
        expect(resumed.lands.pos % @session.transport.bar_length).to eq(0) # (on a bar line)
        # Space while a stop still fades it out: the stop is cancelled, the
        # player fades back in where it is (Session#resume, round 2; it
        # used to print "No background player to resume")
        row_state = -> { st[:snap]&.players&.find { |p| p.name == :drums }&.state }
        expect(wait_until { row_state.() == :playing }).to eq(true), row_state.().inspect
        resumes = -> { @session.journal.changes.count { |e| e.kind == :resume && e.subject == :drums } }
        was = resumes.()
        @session.fade_out = 32 # (a stop's fade long enough for the poll to see it fading, with the pump running ahead of real time)
        @term.write(' ') # (playing: stop, a fade over bars)
        expect(wait_until { %i[fading stopping].include?(row_state.()) }).to eq(true), row_state.().inspect
        @term.write(' ') # (still fading: resume)
        expect(wait_until { resumes.() == was + 1 }).to eq(true)
        expect(wait_until { @session.players.key?(:drums) && @session.stopped.empty? && row_state.() == :playing }).to eq(true), row_state.().inspect
        expect(@term.text).not_to include('No background player')

        before = @session.level(:drums).to_f
        turns = -> { @session.journal.changes.select { |e| e.kind == :turn && e.subject == :"drums/level" } }
        @term.write("\e[D")
        expect(@term.wait_for(/▸drums\s+-1 dB/)).to eq(true), @term.lines.grep(/drums/).first.inspect
        # (live at once, unjournaled; one level line when the keys stop, on
        # the pane's last row, not in the REPL pane: round 2)
        expect(wait_until { (@session.level(:drums).to_f - -1.db.to_f).abs < 1e-3 }).to eq(true)
        expect(wait_until { turns.().length == 1 }).to eq(true)
        expect(turns.()[0].data).to include(gesture: true)
        expect(wait_until { st[:turn_line] == 'level :drums, -1.0.db' }).to eq(true), st[:turn_line].inspect
        rows_of = ->(pane) { r = @tiles.tiler.placed.find { |p| p.name == pane }.rect; @term.lines[r.y, r.h].map { |l| l[r.x, r.w].to_s } }
        expect(wait_until { rows_of.(:tracks).any? { |l| l.include?('level :drums, -1.0.db') } }).to eq(true), rows_of.(:tracks).join("\n")
        expect(rows_of.(:repl).join("\n")).not_to include('level :drums')
        MB::Sound::Session.with_context(session: @session) { @session.undo(on: :now) }
        expect(wait_until { (@session.level(:drums).to_f - before).abs < 1e-9 }).to eq(true) # (one undo: the level from before the gesture)
        expect(@tiles.mode_problems).to eq([])
      ensure
        stop = true
        pump&.join
      end
    end
  end

  it 'logs landed changes newest at the bottom' do
    landed = [ui::LandedInfo.new(seq: 1, kind: :add, subject: :bass, lands: '9:1', pos: 8r, at: nil),
              ui::LandedInfo.new(seq: 2, kind: :mute, subject: :pad, lands: '17:1', pos: 16r, at: nil)].freeze
    lines = draw(:log, snap_with(landed: landed), 30, 4)
    expect(lines[0, 2]).to eq(['9:1    add :bass', '17:1   mute :pad'])
  end

  it 'shows queued changes in the launch lane, counting down to the next, and flashes one that landed' do
    lines = draw(:lane, ui_fake_snapshot, 41, 4)
    # pos 16.5 (17:3): the knob change at 16.5 is due now, the mute at 17 two beats on
    expect(lines[0]).to eq('next knob :cut in 0.0 beats')
    expect(lines[1]).to start_with('▶◆')
    expect(lines[1]).to include('◆')
    flash = [ui::LandedInfo.new(seq: 3, kind: :scene, subject: :drop, lands: '17:1', pos: 16r, at: MB::U.clock_now)].freeze
    expect(draw(:lane, snap_with(landed: flash), 41, 4)[0]).to include('landed: scene :drop')
  end

  it 'shows mapped controllers beside their knobs and the latest MIDI events' do
    midi = ui::MidiInfo.new(events: [['17:1', :keys, :on, 'C4 v100'], ['17:2', :keys, :cc, 'cc 21 = 64']].freeze, ccs: { 21 => 64 }.freeze, mapped: [[:cut, 21]].freeze)
    lines = draw(:midi, snap_with(midi: midi), 50, 5)
    expect(lines[0]).to start_with('cut    cc21')
    expect(lines.join("\n")).to include('C4 v100', 'cc 21 = 64')
  end

  it 'gathers buses, routes, landed changes, clips, and MIDI from a Session (Poll)' do
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    MB::Sound::Session.with_context(session: session) do
      session.bus(:verb) { |sig| sig * 0.5 }
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop.named(:riff)
      session.arrangement.track(:bass, q: 1) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }
      session.route(:bass, send: { verb: 0.5 })
      session.arrangement.play(:bass, clip)
      4.times { session.process_buffer }
      poll = ui::Poll.new(session)
      slow, = poll.call
      expect(slow.buses.map(&:name)).to eq([:verb])
      expect(slow.routes[:bass][:send][:verb]).to be_within(1e-9).of(0.5)
      expect(slow.clips.map(&:name)).to include('riff')
      riff = slow.clips.find { |c| c.name == 'riff' }
      expect(riff.pattern).to start_with('█')
      expect(riff.used).to include(:bass)
      expect(slow.landed.map(&:subject)).to include(:bass)
      expect(slow.midi).to be_a(ui::MidiInfo)
      poll.close
    end
  ensure
    session&.close
    MB::Sound.rewind
  end

  it 'draws meters and scopes from the snapshot being heard, not the newest' do
    band, = ui_fake_band(:band)
    now = MB::U.clock_now
    old = ui_fake_snapshot(t: now - 0.03, seq: 1).with(latency: 0.02)
    newer = ui_fake_snapshot(t: now - 0.005, seq: 2).with(latency: 0.02)
    expect(band.send(:heard, old, now)).to equal(old)
    expect(band.send(:heard, newer, now)).to equal(old) # (heard 15 ms from now)
    expect(band.send(:heard, ui_fake_snapshot(seq: 3), now).seq).to eq(3) # (no latency: the newest)
  end
end
