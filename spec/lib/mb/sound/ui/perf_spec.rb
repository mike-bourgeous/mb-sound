require_relative '../../../../support/ui_helpers'

RSpec.describe(MB::Sound::UI::Perf) do
  let(:perf_class) { MB::Sound::UI::Perf }

  # A fake clock the examples move by hand
  let(:clock) { Struct.new(:t) { def call = t }.new(100.0) }

  def frame(f, at:, late: 0.0, paint: 0.001, write: 0.0005, skipped: 0)
    MB::Sound::UI::Pacer::Frame.new(at: at, paint: paint, write: write, sleep: 0.01, slept: 0.01, late: late, skipped: skipped, wrote: 0)
  end

  describe 'records' do
    it 'keeps each frame, the worst gap between written frames, and pane update ages' do
      p = perf_class.new(clock: clock, ack: nil)
      t = 100.0
      10.times do |i|
        t += i == 6 ? 0.2 : 1 / 60.0
        p.begin_frame(t)
        p.pane_drew(:scope, t, i.zero? ? nil : t - (i == 6 ? 0.2 : 1 / 60.0))
        p.painted(1, false, i.zero?, 500)
        p.wrote(t + 0.001, t + 0.002)
        p.end_frame(frame(p, at: t, late: i == 6 ? 0.18 : 0.0))
      end
      clock.t = t
      s = p.summary
      expect(s[:frames]).to eq(10)
      expect(s[:full_redraws]).to eq(1)
      expect(s[:late_ms][:max]).to eq(180.0)
      expect(s[:worst_written_gap][:ms]).to be_within(0.1).of(200.0)
      expect(s[:panes][:scope][:max]).to be_within(0.01).of(200.0)
      expect(s[:panes][:scope][:stale]).to eq(1)
      expect(s[:stalest_pane][:name]).to eq(:scope)
      expect(p.headline[0]).to match(/worst stall: 200\.\d ms/)
    end

    it 'times a key to the first frame written after its handler ran (REPL keys: a frame that redrew the REPL)' do
      p = perf_class.new(clock: clock, ack: nil)
      p.key(100.0, 100.001, false) # a NAV key
      p.key(100.0, 100.001, true)  # a REPL key: its echo comes through the pty
      p.begin_frame(100.010)
      p.painted(1, false, false, 100)
      p.wrote(100.011, 100.012)
      p.begin_frame(100.030)
      p.painted(1, true, false, 100)
      p.wrote(100.031, 100.032)
      s = p.summary
      expect(s[:keys][:n]).to eq(2)
      expect(s[:keys][:min]).to eq(12.0)
      expect(s[:keys][:max]).to eq(32.0)
      expect(s[:keys][:no_change]).to eq(0)
    end

    it 'counts a key no frame showed within KEY_TIMEOUT as no change' do
      p = perf_class.new(clock: clock, ack: nil)
      p.key(100.0, 100.001, true)
      p.begin_frame(101.5)
      p.painted(1, false, false, 100)
      p.wrote(101.5, 101.6)
      expect(p.summary[:keys]).to include(n: 0, no_change: 1)
    end

    it 'sends a query after a sampled frame and takes its answer out of the input, counting lost ones' do
      p = perf_class.new(clock: clock, ack: :da1, ack_every: 0.25)
      expect(p.ack_query(100.0)).to eq("\e[c")
      expect(p.ack_query(100.01)).to be_nil # (one at a time)
      p.wrote(100.0, 100.002)
      reply = MB::Term::Input::Reply.new(kind: :device, data: [62, 22])
      expect(p.reply(reply, 100.007)).to eq(true)
      expect(p.reply(reply, 100.008)).to eq(false) # (not ours: none was asked)
      expect(p.ack_query(100.1)).to be_nil # (not due yet)
      expect(p.ack_query(100.3)).to eq("\e[c")
      p.wrote(100.3, 100.3)
      expect(p.ack_query(103.0)).to eq("\e[c") # (the last one lost after ACK_TIMEOUT: counted, and the next one goes)
      s = p.summary[:acks]
      expect(s).to include(queries: 3, answered: 1, lost: 1)
      expect(s[:from_write_end_ms][:p50]).to eq(5.0)
      expect(s[:from_write_start_ms][:p50]).to eq(7.0)
    end

    it 'records XTVERSION and DA2 answers as the identity, asked with the next written frame' do
      p = perf_class.new(clock: clock, ack: :da1)
      term = Object.new
      p.identify(features: { device: [62, 22], sync: true }, term: term, size: [40, 120])
      expect(p.expect_dcs?(100.0)).to eq(true)
      expect(p.ack_query(100.0)).to eq("\e[>0q\e[>c")
      expect(p.reply(MB::Term::Input::Reply.new(kind: :dcs, data: '>|Konsole 24.08.3'), 100.01)).to eq(true)
      expect(p.reply(MB::Term::Input::Reply.new(kind: :device2, data: [1, 240_802, 0]), 100.01)).to eq(true)
      expect(p.identity).to include(xtversion: 'Konsole 24.08.3', da2: [1, 240_802, 0], da1: [62, 22], size: [40, 120])
      expect(p.expect_dcs?(100.02)).to eq(false)
    end

    it 'allocates nothing per frame while recording' do
      p = perf_class.new(clock: clock, ack: nil)
      f = frame(p, at: 100.0)
      run = ->(n) {
        n.times do |i|
          t = 100.0 + i / 60.0
          p.begin_frame(t)
          p.pane_drew(:scope, t, t - 0.016)
          p.painted(2, true, false, 400)
          p.wrote(t, t + 0.001)
          p.end_frame(f)
        end
      }
      run.(10)
      before = GC.stat(:total_allocated_objects)
      run.(1000)
      expect(GC.stat(:total_allocated_objects) - before).to be < 20
    end
  end

  describe 'report and save' do
    it 'prints a page with frames, panes, keys, the terminal, and writes report.txt, summary.json, frames.json' do
      p = perf_class.new(clock: clock, ack: :da1)
      p.begin_frame(100.0)
      p.pane_drew(:meters, 100.0, 99.98)
      p.painted(1, false, true, 2000)
      p.wrote(100.0, 100.001)
      p.end_frame(frame(p, at: 100.0))
      clock.t = 101.0
      text = MB::U.remove_ansi(p.report.to_s)
      expect(text).to include('UI frame instruments', 'Frames', 'Panes', 'meters', 'Keys and the terminal', 'Terminal')
      dir = p.save(tmp_path('cap'))
      expect(File.read(File.join(dir, 'report.txt'))).to include('worst stall')
      json = JSON.parse(File.read(File.join(dir, 'summary.json')))
      expect(json).to include('frames' => 1, 'machine' => a_hash_including('cores'))
      frames = JSON.parse(File.read(File.join(dir, 'frames.json')))
      expect(frames['bytes']).to eq([2000])
      expect(frames['pane_gaps']['meters'].length).to eq(1)
      # The per-frame panes column stays (it was once overwritten by the
      # per-pane gaps), with which panes each frame drew
      expect(frames['panes']).to eq([1])
      expect(frames['panes_drawn']).to eq([['meters']])
      expect(frames['pane_names']).to eq(['meters'])
    end

    it 'says which panes each frame drew, so slow frames can be attributed' do
      p = perf_class.new(clock: clock, ack: nil)
      [[100.0, %i[scope meters]], [100.02, %i[transport]], [100.04, []]].each do |t, names|
        p.begin_frame(t)
        names.each { |n| p.pane_drew(n, t, t - 0.016) }
        p.painted(names.length, false, false, names.empty? ? 0 : 300)
        p.wrote(t, t + 0.001) unless names.empty?
        p.end_frame(frame(p, at: t))
      end
      expect(p.records[:panes]).to eq([2, 1, 0])
      expect(p.records[:pane_mask].map { |m| p.panes_in(m) }).to eq([%i[scope meters], %i[transport], []])
      expect(p.pane_names).to eq(%i[scope meters transport])
    end
  end

  # ui.perf :capture as a user hits it (the run itself needs a real
  # screen: bin/ui_bench.rb and the pty runs in the report cover it)
  describe 'capture' do
    let(:cap) { MB::Sound::UI::Perf::Capture }
    let(:out) { StringIO.new }

    after do
      cap.cancel
      cap.thread&.join(2)
      # (a cancel stays set until the next start; Capture.run called
      # directly, as 'capture run' below does, would skip its phase 2:
      # seen in a spec:quick process, 2026-11-18)
      cap.instance_variable_set(:@cancel, false)
    end

    it 'names the settings it ran with (smooth, waves, yielding, YJIT, the screen\'s age) in one line' do
      perf = MB::Sound::UI::Perf
      st = perf.settings(nil)
      expect(st[:smooth]).to eq(:off)
      expect(st[:waves]).to eq(:off)
      expect(perf.settings_line(st)).to match(/\Asettings: smooth off, waves off, yielding on \(painter on, input on\); Ruby \S+ (no YJIT|YJIT .*); screen up -\z/)
      was = [MB::Sound::UI::Feed.every_buffer, MB::Sound::UI::FrameRate.snapshot_timed, MB::Sound::UI::Tiles.echo_wake, MB::Sound::UI::WaveView.mode]
      MB::Sound::UI::Feed.every_buffer = MB::Sound::UI::FrameRate.snapshot_timed = MB::Sound::UI::Tiles.echo_wake = true
      MB::Sound::UI::WaveView.mode = :live
      screen = Struct.new(:seconds_up).new(4.25)
      line = perf.settings_line(perf.settings(screen))
      expect(line).to include('smooth on, waves live', 'screen up 4.3 s (cold: its first 20 s compile)')
    ensure
      MB::Sound::UI::Feed.every_buffer, MB::Sound::UI::FrameRate.snapshot_timed, MB::Sound::UI::Tiles.echo_wake, MB::Sound::UI::WaveView.mode = was if was
    end

    it 'refuses a second capture while one runs, and :cancel stops a running one' do
      release = Queue.new
      allow(cap).to receive(:run) { |**| release.pop; cap.wait(30) ? :done : :cancelled }
      expect(cap.cancel).to eq(false) # (none running)
      cap.start(seconds: 1, out: out)
      expect(cap.start(seconds: 1, out: out)).to be_nil
      expect(out.string).to include('is running already', 'ui.perf :cancel')
      release << true
      expect(cap.cancel).to eq(true)
      expect(cap.thread.join(2)&.value).to eq(:cancelled)
    end

    it 'says in one line what failed, and a new capture can start after it' do
      allow(cap).to receive(:run).and_raise(RuntimeError, 'could not open ui :tiles (is this console in a terminal?)')
      cap.start(seconds: 1, out: out)
      cap.thread.join(2)
      fail_lines = out.string.lines.grep(/failed/)
      expect(fail_lines.length).to eq(1)
      expect(fail_lines[0]).to include('RuntimeError: could not open ui :tiles')
      expect(out.string.lines.length).to eq(2) # (the start line and the failure)
      expect(cap.thread.alive?).to eq(false)
    end
  end

  # Capture.run on a real tiled screen, with the console lines it runs
  # recorded instead of run and the Session a non-realtime one (the
  # maintainer's 2026-11-16 captures: a second capture adopted the first's
  # :ui_perf track and recorded a stopped set; his keys sent the scripted
  # arrows to the track levels)
  describe 'capture run' do
    let(:cap) { MB::Sound::UI::Perf::Capture }
    let(:design) { MB::Sound::UI::Design }
    let(:out) { StringIO.new }
    let(:session) { MB::Sound::Session.new(realtime: false) }
    let(:lines) { [] }
    let(:tracks) { {} }

    before do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      @term.wait_for('t> ')
      MB::Sound::UI.instance_variable_set(:@tiles, @tiles)
      allow(MB::Sound::Session).to receive(:current).and_return(session)
      allow(session.arrangement).to receive(:tracks).and_return(tracks)
      allow(MB::Sound::UI).to receive(:run_line) { |code, _s| lines << code; nil }
      @last_was = design.last
      stub_const('MB::Sound::UI::Perf::Capture::STEP', 0.02)
      stub_const('MB::Sound::UI::Perf::Capture::LAND', 0.05) # (no sound screen here: the inspector never shows the track)
      allow(cap).to receive(:bar_seconds).and_return(0.01) # (a wait for the track lasts LAND or 3.5 bars)
    end

    after do
      MB::Sound::UI.instance_variable_set(:@tiles, nil)
      design.last = @last_was
      @tiles&.stop
      @term&.close
      session.close
    end

    it 'removes a temporary track an earlier run left, makes its own, removes it at the end, and never opens a designed track that is gone' do
      tracks[:ui_perf] = :leftover
      design.last = :bass # (designed once, since untracked: `design :bass` would make it again)
      removed = 0
      allow(cap).to receive(:remove_track) { removed += 1; tracks.delete(:ui_perf); true }
      allow(cap).to receive(:listen).and_return({ audible: true, peak_db: -9.5, buffers: 20, players: [:drums] })
      dir = cap.run(seconds: 2.5, dir: tmp_path('cap'), out: out)
      expect(removed).to eq(2) # (the leftover first, its own at the end)
      expect(lines).to include('design :ui_perf', 'design off')
      expect(lines).not_to include('design :bass')
      expect(design.last).to eq(:bass) # (put back: `design` alone opens what it opened before)
      expect(out.string).to include("removed a :ui_perf track an earlier capture left")
      expect(File.exist?(File.join(dir, 'design', 'frames.json'))).to eq(true)
    end

    it 'decides whether anything plays by the mix, starts the demo when nothing does, and says so in the settings line' do
      heard = [{ audible: false, peak_db: nil, buffers: 0, players: [] }, { audible: true, peak_db: -12.0, buffers: 20, players: [:drums] }]
      allow(cap).to receive(:listen) { heard.shift }
      allow(cap).to receive(:wait).and_call_original
      allow(cap).to receive(:wait).with(2.0).and_return(true) # (the set settling: not needed here)
      cap.run(seconds: 1.0, dir: tmp_path('cap'), out: out)
      expect(lines.first).to eq('demo')
      expect(lines).to include('stop :all') # (what it started, it stops)
      text = MB::U.remove_ansi(out.string)
      expect(text).to include('nothing was playing: loaded demo')
      expect(text).to match(/audio playing \(peak -12\.0 dBFS\), no set, [0-9.]+ bpm, buffer \d+ frames \([0-9.]+\/s\), [0-9.]+ snapshots\/s/)
    end

    # A demo replaces the whole set, its Arrangement included
    # (Session#clear_set, fixes-15): the capture read the scenes from the
    # Arrangement before the demo, found none, and recorded silence
    # ("loaded demo :\"\" and went to nil" on a pty, 2026-11-18)
    it 'reads the scenes from the set the demo loaded, which replaces the Arrangement' do
      set = Struct.new(:tracks, :scenes, :demo_document)
      loaded = set.new({ drums: :drums }, { intro: :intro, groove: :groove }, Struct.new(:name).new('night_bus'))
      current = session.arrangement
      allow(session).to receive(:arrangement) { current }
      allow(MB::Sound::UI).to receive(:run_line) { |code, _s| lines << code; current = loaded if code == 'demo'; nil }
      heard = [{ audible: false, peak_db: nil, buffers: 0, players: [] }, { audible: true, peak_db: -10.0, buffers: 20, players: [:drums] }]
      allow(cap).to receive(:listen) { heard.shift }
      allow(cap).to receive(:wait).and_call_original
      allow(cap).to receive(:wait).with(2.0).and_return(true)
      cap.run(seconds: 1.0, dir: tmp_path('cap'), out: out)
      expect(lines.first(2)).to eq(['demo', 'go :groove'])
      text = MB::U.remove_ansi(out.string)
      expect(text).to include('nothing was playing: loaded demo :night_bus and went to :groove', 'demo :night_bus')
    end

    it 'records a silent set as such when there is nothing to start' do
      tracks[:pad] = :pad # (a set without scenes)
      allow(cap).to receive(:listen).and_return({ audible: false, peak_db: nil, buffers: 0, players: [] })
      cap.run(seconds: 1.0, dir: tmp_path('cap'), out: out)
      text = MB::U.remove_ansi(out.string)
      expect(text).to include('audio NOT playing (silent)', 'a set of 1 tracks', 'nothing was playing and the set has no scenes')
      expect(lines).not_to include('stop :all')
    end

    it 'stops the scripted keys with one line when the focus or the pick moves, and sets the swept knob back' do
      tracks[:bass] = :bass
      design.last = :bass
      knob = Struct.new(:value).new(0.5)
      allow(session).to receive(:knobs).and_return({ cut: knob })
      allow(cap).to receive(:listen).and_return({ audible: true, peak_db: -9.5, buffers: 20, players: [:bass] })
      allow(cap).to receive(:pick_knob).and_return(:cut)
      targets = [[:inspector, :pane, :cut]] * 5 + [[:tracks, :nav, nil]]
      allow(cap).to receive(:key_target) { targets.length > 1 ? targets.shift : targets.first }
      typed = []
      allow(@tiles).to receive(:type_scripted) { |b| typed << b; knob.value = 0.9; @tiles }
      # (his keys: two arrived from the terminal while the script ran)
      allow_any_instance_of(MB::Sound::UI::Perf).to receive(:typed_keys).and_return(2)
      cap.run(seconds: 4.0, dir: tmp_path('cap'), out: out)
      expect(typed.length).to eq(4) # (the expected target read once, then 4 keys checked against it)
      text = MB::U.remove_ansi(out.string)
      expect(text.lines.grep(/phase 2 stopped/).length).to eq(1)
      expect(text).to include('phase 2 stopped after 4 scripted keys: the focus is :tracks in nav mode', '2 keys came from the terminal', "(don't type then)")
      expect(lines).not_to include('stop :all')
      expect(lines).to include('design :bass', 'turn :cut, 0.5') # (the knob set back by a console line)
    end

    # The maintainer's two tunnel_vision captures (2026-11-21): phase 2
    # stopped after 21 keys, "picking nil", telling him not to type though
    # he hadn't; the flow's next scene had stopped the temporary track (a
    # scene stops the tracks it doesn't name) and the inspector fell back
    # to the first playing one.  No key from the terminal: the keys wait,
    # the track starts again, and the sweep goes on (the set and its form
    # never paused: their load is what phase 2 measures).
    it 'holds the keys when the pick moves by itself, starts the temporary track again, and goes on, the set playing on' do
      allow(cap).to receive(:listen).and_return({ audible: true, peak_db: -9.5, buffers: 20, players: [:drums] })
      allow(cap).to receive(:remove_track) { true }
      allow(cap).to receive(:pick_knob).and_return(:'ui_perf/cutoff')
      allow(cap).to receive(:wait_drawn).and_return(true)
      allow(session).to receive(:ui_graphs).and_return({ drums: :graph }) # (:ui_perf stopped by the set)
      allow(session).to receive(:playing_after_queue?).and_return(false)
      allow(MB::Sound::UI::Inspect).to receive(:target).and_return({ track: :ui_perf, node: nil })
      # (the inspector shows the first playing track until :ui_perf plays again)
      allow(cap).to receive(:drawn_track) { lines.include?('bg :ui_perf') ? :ui_perf : :drums }
      ok = [:inspector, :pane, :'ui_perf/cutoff']
      targets = [ok] * 4 + [[:inspector, :pane, nil]] + [ok] * 1000
      allow(cap).to receive(:key_target) { targets.shift || ok }
      typed = []
      allow(@tiles).to receive(:type_scripted) { |b| typed << b; @tiles }
      cap.run(seconds: 2.5, dir: tmp_path('cap'), out: out)
      text = MB::U.remove_ansi(out.string)
      expect(text).not_to include('phase 2 stopped', "don't type")
      expect(text).to include('phase 2 held its keys 1 time', 'no key typed', 'the set and its form playing on', 'the set stopped :ui_perf', 'the capture started :ui_perf again (1 time)')
      expect(lines).to include('design :ui_perf', 'bg :ui_perf')
      expect(lines).not_to include(/pause|stop :all/) # (the set and its form play on)
      expect(typed.length).to be > 4 # (the sweep went on after the pause)
    end

    it 'stops with "by itself" (not "don\'t type then") when the screen does not come back and no key was typed' do
      allow(cap).to receive(:listen).and_return({ audible: true, peak_db: -9.5, buffers: 20, players: [:drums] })
      allow(cap).to receive(:remove_track) { true }
      allow(cap).to receive(:pick_knob).and_return(:'ui_perf/cutoff')
      allow(session).to receive(:ui_graphs).and_return({ drums: :graph })
      ok = [:inspector, :pane, :'ui_perf/cutoff']
      targets = [ok] * 3
      allow(cap).to receive(:key_target) { targets.shift || [:inspector, :pane, nil] }
      allow(@tiles).to receive(:type_scripted) { @tiles }
      cap.run(seconds: 2.5, dir: tmp_path('cap'), out: out)
      text = MB::U.remove_ansi(out.string)
      expect(text).to include('phase 2 stopped after 2 scripted keys', 'with no key typed (the screen changed by itself: the set stopped :ui_perf')
      expect(text).not_to include("don't type")
    end

    # A Down pressed while the inspector still shows the first playing
    # track (the designed one lands on its launch point) moved the
    # inspector to that track (Inspector#key_pick): a pty run, 2026-11-21
    it 'picks a knob only on the track it designs, never pressing Down on another' do
      insp = Class.new { private def picked(_state) = nil }.new
      tiles = double('tiles', pane_object: insp, pane_state: {})
      downs = 0
      allow(tiles).to receive(:type_scripted) { downs += 1; tiles }
      allow(cap).to receive(:drawn_track).and_return(:drums)
      expect(cap.pick_knob(tiles, tries: 3, track: :ui_perf)).to be_nil
      expect(downs).to eq(0)
      allow(cap).to receive(:drawn_track).and_return(:ui_perf)
      expect(cap.pick_knob(tiles, tries: 3, track: :ui_perf)).to be_nil
      expect(downs).to eq(3)
    end
  end

  describe "on the tiled screen" do
    after { @tiles&.stop; @term&.close }

    it 'records real frames, keys typed in the REPL, and terminal answers that never reach Pry or NAV' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      @term.wait_for('t> ')
      p = @tiles.start_perf(ack_every: 0.05)
      # An XTVERSION answer (a DCS the decoder would otherwise read as
      # Alt-P and text) and a DA2 answer, as a terminal sends them
      @term.write("\eP>|Konsole 24.08.3\e\\\e[>1;240802;0c")
      wait_until { p.identity[:da2] }
      wait_until { p.summary[:acks][:answered] >= 3 }
      @term.type('12')
      wait_until { p.summary[:keys][:n] >= 2 }
      @tiles.stop_perf
      s = p.summary
      expect(s[:frames]).to be > 5
      expect(s[:acks][:lost]).to eq(0)
      expect(s[:panes]).not_to be_empty
      expect(s[:keys][:p95]).to be < 1000
      # The answers never reached Reline (no "62;22c" typed) nor the status line
      expect(@term.text).not_to include('62;22c')
      expect(@tiles.host.vt.text).not_to include('62')
      expect(@tiles.host.vt.text).not_to include('Konsole')
      expect(p.identity[:xtversion]).to eq('Konsole 24.08.3')
      expect(s[:keys][:n]).to eq(2) # (the answers aren't keys)
      expect(p.typed_keys).to eq(2) # (from the terminal)
      expect(@tiles.perf).to be_nil
      # The data rate beside the frame rate (no song here: no snapshots)
      expect(s[:data_per_s]).to eq(0.0)
      expect(MB::U.remove_ansi(p.report(s).to_s)).to include('0.0 snapshots/s (new data')
    end

    it 'times scripted keys (the capture\'s knob turns) like typed ones, handled through the Router' do
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100)
      @term.wait_for('t> ')
      p = @tiles.start_perf
      @tiles.type_scripted('ab')
      expect(@term.wait_for('t> ab')).to eq(true) # (to the REPL, as typed)
      wait_until { p.summary[:keys][:n] >= 2 }
      expect(p.summary[:keys][:n]).to eq(2)
      expect(p.typed_keys).to eq(0) # (scripted: not his)
      @tiles.stop_perf
      expect(@tiles.pane_object(:no_such_pane)).to be_nil
      expect(MB::Sound::UI::Perf::Capture.pick_knob(@tiles)).to be_nil # (no inspector on this layout)
    end
  end
end
