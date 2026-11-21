require_relative '../../../../support/ui_helpers'

# Enter on a track, by screen (tracks-enter-1; the maintainer's "track
# enter: maybe focus that track's knobs in :wall, design that track in
# :design", then "Do 'by screen'"): on a performance screen the knobs pane
# shows the track's knobs (pinned until Esc, which comes back to the track),
# on a design screen (one with an inspector) Enter designs it; i designs it
# from any screen.  Keys return PaneKeys results; the screen runs them.
RSpec.describe('Enter on a track', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pk) { ui::PaneKeys }
  let(:knobs) { ui.panes.fetch(:knobs) }
  let(:tracks) { ui.panes.fetch(:tracks) }
  # (cut, drive, bass/dub/space, bass/dub/tone; drums' graph reads :cut)
  let(:snap) do
    s = ui_fake_snapshot(rack_knobs: true)
    s.with(slow: s.slow.with(knob_users: { drums: %i[cut].freeze, pad: [].freeze }.freeze, knob_specs: s.knobs.to_h { |k| [k.name, k.spec] }.freeze))
  end

  def lines(snap, state, w: 40, h: 6)
    grid = MB::Term::Cells.new(w, h)
    state[:title_in_rule] = true
    knobs.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  describe 'the knobs of a track' do
    it 'are those named under it and those its graph reads, in the snapshot order' do
      expect(ui::Panes::Knobs.of_track(snap, :bass).map(&:name)).to eq(%i[bass/dub/space bass/dub/tone])
      expect(ui::Panes::Knobs.of_track(snap, :drums).map(&:name)).to eq(%i[cut])
      expect(ui::Panes::Knobs.of_track(snap, :pad)).to eq([])
      expect(ui::Panes::Knobs.of_track(nil, :pad)).to eq([])
      expect(ui::Panes::Knobs.names_of_track(snap, :bass)).to eq(%i[bass/dub/space bass/dub/tone])
      expect(ui::Panes::Knobs.names_of_track(snap.with(knobs: [].freeze), :drums)).to eq(%i[cut]) # (the poll's names, before the first values)
    end

    it 'come from the graphs that joined the Session (Session#knob_readers) and the build knobs, through the poll' do
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.knob(:cut, 800, range: 100..8000)
        MB::Sound.bg(:hiss, MB::Sound.noise.filter(:lowpass, cutoff: MB::Sound.knob(:cut), quality: 0.7))
        MB::Sound.bg(:hum, 60.hz)
      end
      s.process_buffer
      expect(s.knob_readers).to eq({ hiss: %i[cut], hum: [] })
      expect(s.knob_readers).to be_frozen
      slow, = ui::Poll.new(s).call
      expect(slow.knob_users).to equal(s.knob_readers) # (no build knobs: the Session's Hash itself)
    ensure
      s&.close
      MB::Sound.rewind
    end
  end

  describe 'in the knobs pane' do
    it "lists only the track's knobs, titled with it, the cursor on the first, keys turning them" do
      st = { mode: true, snap: snap }
      expect(knobs.key_track(st, :bass, :tracks)).to eq(['knobs: bass (2)  Left Right turn  t T other tracks  Esc back to the tracks'])
      expect(knobs.state_title(st)).to eq('knobs: bass')
      shown = lines(snap, st)
      expect(shown[0]).to start_with('bass/du')
      expect(shown.join("\n")).not_to include('cut', 'drive')
      expect(knobs.key_action(:reset, st)[0].code).to start_with('turn :"bass/dub/space", ')
      expect(knobs.key_pick(st, 5)).to include('bass/dub/tone')
      expect(st[:pick]).to eq(1) # (clamped to the track's two)
      # (outside its mode: still pinned to the track)
      st[:mode] = false
      expect(lines(snap, st).join("\n")).not_to include('cut')
      expect(knobs.state_title({})).to be_nil
    end

    it 'steps to the next and previous track with knobs with t and T' do
      st = { mode: true, snap: snap }
      knobs.key_track(st, :bass, :tracks)
      expect(knobs.key_other_track(st, 1)).to eq(['knobs: drums (1)  Left Right turn  t T other tracks  Esc back to the tracks']) # (lead and pad have none)
      expect(st[:from]).to eq(:tracks)
      expect(knobs.key_other_track(st, -1).first).to start_with('knobs: bass (2)')
      expect(knobs.key_other_track({ snap: snap }, 1)).to include('after Enter on a track')
    end

    it 'goes back to the tracks pane on the track with Esc, the filter gone; Esc without one is NAV as before' do
      st = { mode: true, snap: snap }
      knobs.key_track(st, :bass, :tracks)
      knobs.key_other_track(st, 1)
      expect(knobs.key_escape(st)).to eq([pk::Focus[:tracks, :returned, :drums, leave: true]])
      expect(st[:track]).to be_nil
      expect(knobs.state_title(st)).to be_nil
      expect(lines(snap, st).join("\n")).to include('drive')
      expect(knobs.key_escape(st)).to be_nil
      t = { snap: snap }
      expect(tracks.key_action(:returned, t, :drums, :knobs)).to include('drums (Enter its knobs')
      expect(t[:cursor]).to eq(:drums)
    end

    it 'draws a pinned list without new objects each frame' do
      st = { snap: snap }
      knobs.key_track(st, :bass, :tracks)
      c = ui::Canvas.new(MB::Term::Cells.new(40, 6), 0, 0, 40, 6)
      count = ->(state) { 3.times { knobs.draw_body(c, snap, state) }; GC.disable; a = GC.stat(:total_allocated_objects); 20.times { knobs.draw_body(c, snap, state) }; n = GC.stat(:total_allocated_objects) - a; GC.enable; n }
      expect(count.(st)).to be <= count.({}) + 5
    end
  end

  describe 'in the tracks pane' do
    it 'takes the picked track into the knobs pane on a performance screen, or says it has none' do
      st = { snap: snap, cursor: :bass }
      expect(tracks.key_action(:open, st)).to eq(pk::Focus[:knobs, :track, :bass, rows: 4])
      expect(tracks.key_action(:open, st.merge(cursor: :lead))).to eq('lead has no knobs: i designs it (design :lead)')
      expect(tracks.key_action(:open, { snap: snap })).to eq('pick a track first (Up Down)')
    end

    it 'designs the picked track on a design screen (a console line), or only focuses the inspector already on it' do
      st = { snap: snap, cursor: :pad, design: true }
      expect(tracks.key_action(:open, st)).to eq(pk::Run['design :pad', 'designing pad'])
      info = Struct.new(:track).new(:pad)
      on_pad = snap.with(slow: snap.slow.with(inspector: info))
      expect(tracks.key_action(:open, st.merge(snap: on_pad))).to eq(pk::Focus[:inspector, note: 'designing pad (Esc: NAV)'])
    end

    it 'designs the picked track with i from any screen, tracks only' do
      expect(tracks.key_action(:design, { snap: snap, cursor: :drums })).to eq(pk::Run['design :drums', 'designing drums'])
      expect(tracks.key_action(:design, { snap: snap, cursor: :verb })).to include('not a track')
    end

    it 'lists Enter and i in its keys, t and T in the knobs pane\'s' do
      chords = ->(k) { k.mode_keymap.entries.to_h { |b| [b.chord[0], b.action] } }
      expect(chords.(ui::Panes::Tracks)).to include(enter: :open, 'i' => :design)
      expect(chords.(ui::Panes::Knobs)).to include('t' => :other_track, 'T' => :other_track, enter: :ask)
    end
  end

  describe 'on a screen' do
    after do
      @pump_stop = true
      @pump&.join
      @tiles&.stop
      @term&.close
      @session&.close
      ui::Inspect.target = nil
      ui::Design.instance_variable_set(:@open, false)
      ui::Design.instance_variable_set(:@last, nil)
      ui::Design.instance_variable_set(:@before, nil)
      MB::Sound.rewind
    end

    # A session with a graph reading the knob :cut (:hiss) and one reading
    # none (:hum), rendered by a pump thread.
    def start_session
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.knob(:cut, 800, range: 100..8000)
        MB::Sound.track(:hiss) { |_clip| MB::Sound.noise.filter(:lowpass, cutoff: MB::Sound.knob(:cut), quality: 0.7).at(0.1) }
        MB::Sound.track(:hum) { |_clip| 60.hz.at(0.1) }
        riff = MB::Sound.seq(MB::Sound::C4).n1.loop
        MB::Sound.bg(:hiss, riff)
        MB::Sound.bg(:hum, riff)
      end
      8.times { @session.process_buffer }
      @pump_stop = false
      @pump = Thread.new { until @pump_stop; @session.process_buffer; sleep 0.02; end }
    end

    def states = @tiles.instance_variable_get(:@states)

    # Into the tracks pane with the cursor on +name+, once the pane drew it.
    def tracks_on(name)
      expect(wait_until { states[:tracks][:snap]&.tracks&.any? { |t| t.name == name } && states[:tracks][:snap].knob_users.key?(:hiss) && !states[:tracks][:snap].knobs.empty? }).to be_truthy
      @tiles.enter(:tracks)
      expect(wait_mode(@tiles, :pane)).to eq(true)
      @tiles.instance_variable_get(:@input_lock).synchronize { states[:tracks][:cursor] = name }
    end

    it 'wall: Enter goes into the knobs pane on the track, a turn lands, Esc comes back to the same row' do
      start_session
      @tiles, @term = ui_tiles(:wall, rows: 60, cols: 200, session: @session)
      tracks_on(:hiss)
      @term.write("\r")
      expect(wait_settled(@tiles) { @tiles.tiler.focus == :knobs && @tiles.router.mode == :pane && states[:knobs][:track] == :hiss }).to eq(true), @term.text
      expect(@term.wait_for(/knobs: hiss/i)).to eq(true), @term.text # (the title, and the flash)
      before = @session.knobs[:cut].value
      turns = @session.journal.changes.count { |e| e.kind == :turn }
      @term.write("\e[C")
      expect(wait_until { @session.knobs[:cut].value > before }).to eq(true)
      expect(wait_until { @session.journal.changes.count { |e| e.kind == :turn } == turns + 1 }).to eq(true)
      @term.write("\e")
      expect(wait_settled(@tiles) { @tiles.tiler.focus == :tracks && @tiles.router.mode == :pane }).to eq(true)
      expect(states[:tracks][:cursor]).to eq(:hiss)
      expect(states[:knobs][:track]).to be_nil
      expect(@tiles.mode_problems).to eq([])
    end

    it 'tiles: a knobs pane comes for a while, and Esc puts the layout back as it was' do
      start_session
      @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, session: @session)
      layout = @tiles.tiler.layout
      expect(layout.panes).not_to include(:knobs)
      tracks_on(:hiss)
      @term.write("\r")
      expect(wait_settled(@tiles) { @tiles.tiler.focus == :knobs && states[:knobs][:track] == :hiss }).to eq(true), @term.text
      expect(@tiles.tiler.layout.panes).to include(:knobs, :tracks, :repl)
      expect(@term.wait_for('cut')).to eq(true)
      @term.write("\e")
      expect(wait_settled(@tiles) { @tiles.tiler.focus == :tracks && @tiles.router.mode == :pane }).to eq(true)
      expect(@tiles.tiler.layout).to eq(layout.with(focus: :tracks))
      expect(states[:tracks][:cursor]).to eq(:hiss)
      expect(@tiles.mode_problems).to eq([])
    end

    it 'a track without knobs: says so, nothing opens, the cursor stays' do
      start_session
      @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120, session: @session)
      layout = @tiles.tiler.layout
      tracks_on(:hum)
      @term.write("\r")
      expect(@term.wait_for('hum has no knobs: i designs it')).to eq(true), @term.text
      expect(wait_settled(@tiles) { @tiles.tiler.focus == :tracks && @tiles.router.mode == :pane }).to eq(true)
      expect(@tiles.tiler.layout.panes).to eq(layout.panes)
    end

    it 'the design screen: Enter designs the track (a console line), the inspector on it' do
      start_session
      allow(ui).to receive(:show) { nil } # (design's screen switch: this screen stays)
      @tiles, @term = ui_tiles(:sound, rows: 50, cols: 180, session: @session)
      ui::Inspect.target = { track: :hum, node: nil }.freeze
      tracks_on(:hiss)
      @term.write("\r")
      expect(wait_until { ui::Inspect.target.is_a?(Hash) && ui::Inspect.target[:track] == :hiss }).to eq(true), @term.text
      expect(@term.wait_for('design :hiss')).to eq(true), @term.text # (the line, in the REPL pane)
      expect(ui::Design.last).to eq(:hiss)
    end
  end
end
