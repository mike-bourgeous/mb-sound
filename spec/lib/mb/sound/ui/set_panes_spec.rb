require_relative '../../../../support/ui_helpers'

# Round 4's panes (ux-r4-panes): the clip matrix and its keys, the clip
# detail, racks with knobs to turn, buses with meters, the keyboard
# lighting MIDI input.  Panes draw from ui_fake_snapshot (feed contract
# data); keys return console lines (PaneKeys::Run) the screen runs.
RSpec.describe('UI round 4 panes', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:snap) { ui_fake_snapshot(rack_knobs: true) }

  def draw(name, snap, state = { title_in_rule: true }, w: 60, h: 8)
    grid = MB::Sound::Plot::Text::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  def key(name, state, action, *args) = ui.panes.fetch(name).key_action(action, state, *args)

  describe 'the clip matrix' do
    it 'draws tracks against scenes then other slots, with playing, queued (with a countdown), stop, and keep cells' do
      lines = draw(:clips, snap, w: 70)
      expect(lines[0]).to match(/\A\s+intro\s+▶drop\s+break\s+slots\z/)
      expect(lines[1]).to match(/\A▶drums\s+■\s+▶beat_a\s+fill\z/)
      expect(lines[2]).to include('▶bass_a', '◆bass_b 2.0', 'bass_1') # (queued for 17r, now 16.5r: 2 beats)
      expect(lines[3]).to match(/\A lead\s+■\s+hook\s+·\z/)
      expect(lines[4]).to include('▶chords', '◆■')
    end

    it 'moves a cursor in its mode and launches the cell, its scene, or a stop as console lines' do
      st = { title_in_rule: true, mode: true }
      draw(:clips, snap, st)
      expect(key(:clips, st, :launch)).to eq(ui::PaneKeys::Run['stop :drums', 'stop :drums']) # (intro has drums stopped)
      key(:clips, st, :move, 1, 1) # bass, drop
      expect(key(:clips, st, :launch).code).to eq('launch :bass, 0')
      key(:clips, st, :move, 1, 0)
      expect(key(:clips, st, :launch).code).to eq('launch :bass, 1')
      expect(key(:clips, st, :scene).code).to eq('go :break')
      key(:clips, st, :move, 1, 0) # past the scenes: bass's other slot
      expect(key(:clips, st, :launch).code).to eq('launch :bass, 2')
      expect(key(:clips, st, :scene)).to include('not a scene column')
      key(:clips, st, :move, 9, 9) # clamped to the last cell
      expect(st[:cursor]).to eq([3, 3])
      expect(key(:clips, st, :launch)).to include('nothing in this cell')
      key(:clips, st, :move_to, :first)
      expect(st[:cursor]).to eq([3, 0])
      expect(key(:clips, st, :stop).code).to eq('stop :pad')
    end

    it 'tweaks the track\'s clip with one key per edit, refusing tracks with nothing playing' do
      st = { title_in_rule: true, mode: true }
      draw(:clips, snap, st)
      key(:clips, st, :move, 0, 1) # bass
      codes = ui::Panes::Clips::EDITS.map { |k, _, _| key(:clips, st, :tweak, k).code }
      expect(codes).to eq(['tweak :bass, transpose: 1', 'tweak :bass, transpose: -1', 'tweak :bass, transpose: 12', 'tweak :bass, transpose: -12',
                           'tweak :bass, legato: 1.0', 'tweak :bass, swing: 0.6', 'tweak :bass, quantize: 1/16r', 'tweak :bass, :double',
                           'tweak :bass, :half', 'tweak :bass, :halftime', 'tweak :bass, :doubletime', 'tweak :bass, :reverse'])
      key(:clips, st, :move, 0, 1) # lead: stopped
      expect(key(:clips, st, :tweak, '+')).to eq(':lead plays no clip to tweak')
      expect(key(:clips, st, :undo).code).to eq('undo')
    end

    it 'binds every edit and cursor key in its mode keymap, and declares its jump letter' do
      km = ui::Panes::Clips.mode_keymap
      keys = km.entries.map { |b| b.chord[0].to_s }
      expect(keys).to include('up', 'down', 'left', 'right', 'enter', 'g', 'x', *ui::Panes::Clips::EDITS.map(&:first))
      expect(keys).not_to include('escape')
      expect(ui::Panes::Clips.jump).to eq('a')
      expect(ui::Panes::Racks.jump).to eq('r')
      expect(ui::Panes::Buses.jump).to eq('b')
    end

    it 'publishes the cursor\'s clip for the detail pane, which draws its notes as a roll with marks' do
      st = { title_in_rule: true, mode: true }
      draw(:clips, snap, st)
      key(:clips, st, :move, 1, 1)
      draw(:clips, snap, st)
      expect([ui::Panes::Clips.selected[0], ui::Panes::Clips.selected[1].name]).to eq([:bass, 'bass_a'])
      lines = draw(:clip, snap, h: 10)
      expect(lines[0]).to include('bass_a', '1 bar', 'loop', 'C2..C3', 'on bass', '8 notes')
      expect(lines[1]).to start_with('seq(C2, C2, G2')
      expect(lines.find { |l| l.start_with?('C3') }).to include('█')
      expect(lines.find { |l| l.start_with?('C2') }).to include('!') # (the accent)
      ui::Panes::Clips.selected = nil
      expect(draw(:clip, snap)[0]).to include('beat_a') # (the first playing clip)
      expect(draw(:clip, ui_fake_snapshot.with(slow: ui_fake_slow.with(matrix: nil)))[0]).to start_with('no clip selected')
    ensure
      ui::Panes::Clips.selected = nil
    end

    it 'says how to make tracks when there are none' do
      expect(draw(:clips, ui_fake_snapshot.with(slow: ui_fake_slow.with(matrix: nil)))[0]).to start_with('no tracks yet')
    end
  end

  describe 'racks' do
    it 'draws each instance with its kind, typed ports, latency, and knobs as rows' do
      lines = draw(:racks, snap, w: 50)
      expect(lines[0]).to eq('bass/dub  effect  lat 72 smp')
      expect(lines[1]).to eq('  in sig:audio side:audio?  out audio')
      expect(lines[2]).to match(/\A  space\s+█+.*0\.6 0\.\.1\z/)
      expect(lines[3]).to match(/\A  tone\s+█+.*1800 Hz 600\.\.8000 exp\z/)
      expect(draw(:racks, ui_fake_snapshot.with(slow: ui_fake_slow.with(racks: [].freeze)))[0]).to start_with('no racks')
    end

    it 'picks knobs and turns them by position steps (Shift: fine) as turn lines, from the value it just set' do
      st = { title_in_rule: true, mode: true }
      draw(:racks, snap, st)
      expect(key(:racks, st, :turn, 0.02)).to eq(ui::PaneKeys::Run['turn :"bass/dub/space", 0.62', 'bass/dub/space 0.62'])
      expect(key(:racks, st, :turn, 0.02).code).to eq('turn :"bass/dub/space", 0.64') # (before the knob caught up)
      key(:racks, st, :pick, 1)
      tone = key(:racks, st, :turn, -0.002).code
      expect(tone).to start_with('turn :"bass/dub/tone", 17')
      expect(tone[/[\d.]+\z/].to_f).to be_within(10).of(1800 * (8000 / 600.0)**-0.002)
      expect(key(:racks, st, :reset).code).to eq('turn :"bass/dub/tone", 2400')
      key(:racks, st, :pick, 5) # (clamped)
      expect(key(:racks, st, :turn, 1.0).code).to eq('turn :"bass/dub/tone", 8000')
      expect(key(:racks, { snap: ui_fake_snapshot }, :turn, 0.1)).to include('no knob')
    end
  end

  describe 'buses' do
    it 'shows each bus with input and output meters and what feeds it: routed whole (to:) or by a send level with its meter' do
      lines = draw(:buses, snap, w: 60, h: 6)
      expect(lines[0]).to start_with('● verb').and include('→ master', 'reverb(:hall)')
      expect(lines[1]).to match(/in █.*-14\.0 out █.*-12\.5\z/)
      expect(lines[2]).to match(/\A ← pad\s+-12\.0 dB █.*-20\.0\z/)
      expect(lines[3]).to start_with('● drums')
      expect(lines[5]).to match(/\A ← drums\s+to:\z/)
      expect(ui.panes[:buses].needs).to eq([:buses])
    end

    it 'leaves the meter rows out until the feed sends levels, and follows send levels given as knobs' do
      s = ui_fake_snapshot.with(bus_levels: nil, send_levels: nil, slow: ui_fake_slow.with(routes: { pad: { to: :master, send: { verb: :wet } } }.freeze))
      lines = draw(:buses, s, w: 60, h: 4)
      expect(lines[1]).to match(/\A ← pad\s+follows wet\z/)
    end
  end

  describe 'the keyboard' do
    it 'lights notes from the MIDI input (not its own keys) and names their chord' do
      kb = ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new)
      base = kb.view.base
      notes = [0, 4, 7].map { |d| ui::HeldNote.new(note: base + 12 + d, velocity: 100, channel: 0, source: :input, input: nil, frame: 0, pos: 0r) } +
              [ui::HeldNote.new(note: base + 2, velocity: 90, channel: 0, source: :keyboard, input: nil, frame: 0, pos: 0r)]
      s = ui_fake_snapshot.with(notes: notes.freeze)
      expect(ui::Panes::Keyboard.input_fills(s, base)).to eq({ 12 => [100, :input], 16 => [100, :input], 19 => [100, :input] })
      text = draw(:keyboard, s, { keyboard: kb, title_in_rule: true }, w: 120, h: 12).join("\n")
      expect(text).to match(/input C4 E4 G4\s+C\b/)
      # Pressed vs sounding once a scale transform reports what sounds
      sounding = [ui::HeldNote.new(note: base + 13, velocity: 100, channel: 0, source: :input, input: nil, frame: 0, pos: 0r)].freeze
      s2 = ui_fake_snapshot.with(notes: notes.first(1).freeze, sounding: sounding)
      expect(ui::Panes::Keyboard.input_fills(s2, base)).to eq({ 12 => [100, :pressed], 13 => [100, :input] })
    end
  end

  describe 'with a real Session (Poll, the feed, the console lines the keys run)' do
    before do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    end

    after do
      @poll&.close
      @session&.close
      MB::Sound.rewind # the Session runs on the shared transport (spec/support/transport_guard.rb)
    end

    # A Snapshot of the session now (the feed's per-buffer data with Poll's
    # Slow), as the painter would see it.
    def live_snap
      @poll ||= ui::Poll.new(@session)
      feed = (@feed ||= ui::Feed.new.tap { |f| f.needs = [:buses]; @session.ui_feed = f })
      4.times { @session.process_buffer }
      slow, refs = @poll.call
      feed.knob_refs = refs
      feed.slow = slow
      feed.take
      @session.process_buffer
      s = feed.take
      s.with(slow: slow)
    end

    def run(r) = ui.run_line(r.code, @session)

    it 'launches, tweaks, goes to scenes, stops, and turns rack knobs from pane keys, journaled and undoable, the matrix following' do
      MB::Sound::Session.with_context(session: @session) do
        arr = @session.arrangement
        bass_a = MB::Sound.seq(MB::Sound::C2, MB::Sound::G2).n8.loop.named(:bass_a)
        bass_b = MB::Sound.seq(MB::Sound::F2, MB::Sound::C3).n8.loop.named(:bass_b)
        arr.track(:bass, q: :beat) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }
        arr.scene(:a, bass: bass_a)
        arr.scene(:b, bass: bass_b)
        @session.bus(:verb) { |sig| sig * 0.5 }
        @session.route(:bass, send: { verb: 0.5 })
        MB::Sound.instance_eval do
          arack(:dub) { |sig| sig * knob(:space, 0.35) }
          bg :drone, 110.hz.saw.at(-30.db).then(&rack(:dub))
        end

        st = { title_in_rule: true, mode: true }
        s = live_snap
        expect(draw(:clips, s, st, w: 60)[0]).to match(/\A\s+a\s+b\z/)
        # Enter on (bass, b): launch :bass, 1
        key(:clips, st, :move, 1, 0)
        r = key(:clips, st, :launch)
        expect(r.code).to eq('launch :bass, 1')
        run(r)
        s = live_snap
        30.times { @session.process_buffer } # (to the beat)
        s = live_snap
        expect(s.matrix.tracks.first.playing).to eq(1)
        expect(draw(:clips, s, st, w: 60)[1]).to include('▶bass_b')
        # A tweak: a new slot, playing
        run(key(:clips, st, :tweak, '>'))
        30.times { @session.process_buffer } # (to the beat)
        s = live_snap
        lane = s.matrix.tracks.first
        expect(lane.slots.length).to eq(3)
        expect(lane.slots[lane.playing].events.map(&:note)).to eq([MB::Sound::F3.number, MB::Sound::C4.number])
        draw(:clips, s, st, w: 60)
        expect(draw(:clip, s, h: 8)[0]).to include('bass_b')
        # The scene key and the stop key
        expect(run(key(:clips, st, :scene))).to respond_to(:lands)
        expect(run(key(:clips, st, :stop))).to respond_to(:lands)
        kinds = @session.journal.changes.map(&:kind)
        expect(kinds).to include(:scene, :stop)

        # Racks: the knob, turned
        rk = { title_in_rule: true, mode: true }
        lines = draw(:racks, s, rk, w: 50)
        expect(lines.join("\n")).to include('dub', 'space')
        t = key(:racks, rk, :turn, 0.1)
        expect(t.code).to match(/\Aturn :"(drone\/)?dub\/space", 0\.45\z/)
        run(t)
        4.times { @session.process_buffer }
        expect(@session.knobs.values.find { |k| k.name.to_s.end_with?('dub/space') }.value).to be_within(1e-9).of(0.45)

        # Buses: a meter of the send
        expect(draw(:buses, live_snap, w: 60, h: 6).join("\n")).to include('verb', '← bass')
      end
    end

    it 'launches a clip from the keyboard: NAV, a (the matrix, in its mode), Right, Enter, the line printed in the console' do
      MB::Sound::Session.with_context(session: @session) do
        arr = @session.arrangement
        arr.track(:bass, q: :beat) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.amp_env } }
        arr.scene(:a, bass: MB::Sound.seq(MB::Sound::C2, MB::Sound::G2).n8.loop.named(:bass_a))
        arr.scene(:b, bass: MB::Sound.seq(MB::Sound::F2, MB::Sound::C3).n8.loop.named(:bass_b))
      end
      @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, session: @session)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.005; end }
      expect(@term.wait_for('t> ')).to eq(true)
      @tiles.show(:clips, at: :queue)
      expect(@term.wait_for('bass_b')).to eq(true), @term.text
      @term.write("\x1d")
      expect(@term.wait_for(' NAV ')).to eq(true)
      @term.type('a')
      expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :clips }).to eq(true)
      @term.write("\e[C")
      sleep 0.1
      @term.write("\r")
      expect(@term.wait_for('launch :bass, 1')).to eq(true), @term.text
      expect(wait_until { @session.journal.changes.any? { |e| e.status == :landed && e.subject.to_s.include?('bass') } }).to eq(true)
      expect(@term.wait_for('▶bass_b')).to eq(true), @term.text
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
      @tiles&.stop
      @term&.close
    end
  end

  describe 'running a pane key\'s line on the screen' do
    after do
      @tiles&.stop
      @term&.close
      @session&.close
    end

    it 'runs it through UI.run_line in the screen\'s session (journaled), prints the Ruby in the REPL pane, and flashes its note' do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      @session.knob(:space, 0.2)
      @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100, session: @session)
      expect(@term.wait_for('t> ')).to eq(true)
      @tiles.send(:run_pane_line, ui::PaneKeys::Run['turn :space, 0.7', 'space 0.7'])
      expect(@term.wait_for('turn :space, 0.7')).to eq(true), @term.text
      expect(@term.text).to include('# space 0.7')
      expect(@session.journal.changes.map(&:kind)).to include(:turn)
      @tiles.send(:run_pane_line, ui::PaneKeys::Run['turn :nope_not_a_knob, 1', 'nope'])
      expect(@term.wait_for('ArgumentError')).to eq(true), @term.text
    end
  end
end
