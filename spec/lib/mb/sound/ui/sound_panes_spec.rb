require_relative '../../../../support/ui_helpers'

# The sound-design screen (sound-design-ui-1): the patch inspector's data
# (UI::Inspect, from a real Session's graphs without the render lock), its
# panes drawn from fake and real snapshots, its keys as console lines
# (journaled, undoable), held-key gestures, typed values through
# PaneKeys::Ask on a real screen, the preview and code panes.
RSpec.describe('UI sound-design screen', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:snap) { ui_fake_snapshot }

  before { MB::Sound::UI::Inspect.target = nil }
  after do
    MB::Sound::UI::Inspect.target = nil
    MB::Sound::UI::Panes::Clips.selected = nil
  end

  def draw(name, snap, state = { title_in_rule: true }, w: 60, h: 12)
    grid = MB::Sound::Plot::Text::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  def key(name, state, action, *args) = ui.panes.fetch(name).key_action(action, state, *args)

  SOUND_PANES = %i[inspector preview render code picker audition sound_keys].freeze

  # Ruby class names of node classes (basenames: SampleWrapper, FourPole,
  # ...), which no sound pane may show (omnibus15; maintainer: "it
  # shouldn't mention SampleWrapper").
  def node_class_names
    @node_class_names ||= ObjectSpace.each_object(Class).select { |c|
      c.name&.start_with?('MB::Sound::') && (c.include?(MB::Sound::GraphNode) || c <= MB::Sound::Filter::SampleWrapper)
    }.map { |c| c.name.split('::').last }.uniq
  end

  # Every sound pane's text for each node of +snap+'s inspector (picked in
  # turn by +pick+, a block returning the snapshot with node i picked),
  # plus the inspector's node-stepping messages.
  def sound_text(snap, &pick)
    info = snap.inspector
    texts = []
    (info ? info.nodes.length : 1).times do |i|
      s = pick ? pick.call(i) : snap
      SOUND_PANES.each { |name| texts << draw(name, s, { title_in_rule: true }, w: 100, h: 30).join("\n") }
      texts << key(:inspector, { snap: s }, :node, 1).to_s if info
    end
    texts.join("\n")
  end

  def expect_no_class_names(text)
    found = node_class_names.select { |n| text.match?(/\b#{n}\b/) }
    expect(found).to eq([]), "class names in the sound panes: #{found.join(', ')}\n#{text.lines.grep(/\b(#{found.join('|')})\b/).first(5).join}"
  end

  describe 'the panes with fake data' do
    it 'draws the track, its knob rows, the nodes as chips, and the picked node\'s params' do
      text = draw(:inspector, snap).join("\n")
      expect(text).to include('bass  2/3', 'cut', '2400 Hz', '100..8000 exp', 'nodes lp4×2 highpass×4 softclip×2 saw×6')
      expect(text).to include('highpass  filter ×4  2/4', 'cutoff     150 Hz', 'quality    0.7  Q')
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      expect(draw(:inspector, lp4).join("\n")).to include('cutoff     → knob cut 2400 Hz')
      empty = snap.with(slow: snap.slow.with(inspector: nil))
      expect(draw(:inspector, empty)[0]).to include('nothing to inspect')
    end

    it 'turns, resets, types, and learns the picked knob as console lines; t and n pick tracks and nodes' do
      st = { title_in_rule: true, mode: true }
      draw(:inspector, snap, st)
      pane = ui.panes.fetch(:inspector)
      expect(pane.enter_hint(st)).to eq("type cut's value")
      prev = key(:inspector, st, :turn, ui::KnobTurns::STEP).last
      expect(prev).to be_a(ui::PaneKeys::Preview)
      expect(prev.knob).to eq(:cut)
      expect(prev.value).to be > 2400
      # One step along an exp knob is the same ratio anywhere on it
      spec = snap.knobs.first.spec
      expect(ui::KnobTurns.turned(spec, 1000.0, 0.02) / 1000.0).to be_within(1e-3).of(ui::KnobTurns.turned(spec, 4000.0, 0.02) / 4000.0)
      st.delete(:gesture)
      expect(key(:inspector, st, :reset).last).to eq(ui::PaneKeys::Run['turn :cut, 800', 'cut 800'])
      ask = key(:inspector, st, :ask).last
      expect(ask).to eq(ui::PaneKeys::Ask['turn :cut, ', 800, :typed]) # (the value just set stands in until the snapshot has it)
      expect(key(:inspector, st, :typed, '3000.hz')).to eq(ui::PaneKeys::Run['turn :cut, 3000.hz', 'cut 3000.hz'])
      expect(key(:inspector, st, :typed, '  ')).to eq('nothing typed')
      expect(key(:inspector, st, :learn).last.code).to eq('learn :cut')
      expect(key(:inspector, st, :track, 1)).to include('inspecting pad')
      expect(ui::Inspect.target).to eq({ track: :pad, node: nil })
      expect(key(:inspector, st, :node, 1)).to include('node softclip')
      expect(ui::Inspect.target).to eq({ track: :bass, node: 2 })

      # Tab and Shift-Tab step through the nodes like n and N
      km = ui::Panes::Inspector.mode_keymap
      expect(km[ui::Input::Key.new(key: :tab, mods: [])]).to eq(km[ui::Input::Key.new(key: 'n', mods: [])])
      expect(km[ui::Input::Key.new(key: :tab, mods: [:shift])]).to eq(km[ui::Input::Key.new(key: 'N', mods: [])])
    end

    it 'steps stepped knobs one step at a time' do
      spec = ui_knob_spec(:voices, 4, 1..8)
      expect(ui::KnobTurns.turned(spec, 4.0, 0.002)).to eq(5.0)
      expect(ui::KnobTurns.turned(spec, 1.0, -0.02)).to eq(1.0)
    end

    it 'shows the code with the knob lines at their values now, recomputed only when they change' do
      st = {}
      lines = ui::Panes::Code.lines(snap.inspector, snap.knobs, st)
      expect(lines[0]).to start_with('knob :cut, ').and include('.at(2400.0)')
      expect(lines.join("\n")).to include('# bass: the graph it plays', 'synth(riff, voices: 1)')
      expect(ui::Panes::Code.lines(snap.inspector, snap.knobs, st)).to equal(lines)
      turned = snap.knobs.map { |k| k.name == :cut ? k.with(value: 3100.0) : k }
      expect(ui::Panes::Code.lines(snap.inspector, turned, st)[0]).to include('.at(3100.0)')
      text = draw(:code, snap, w: 40).join("\n")
      expect(text).to include('saws.lp4(knob(:cut), resonance:', '    0.25)') # (wrapped with a hanging indent)
    end

    it 'draws the picked node\'s preview, or says why there is none' do
      text = draw(:preview, snap, {}, w: 50, h: 10).join("\n")
      expect(text).to include('frequency', '1k')
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      expect(draw(:preview, lp4, {}, w: 50, h: 10)[0]).to include('lp4: no preview')
    end

    it 'runs the preview as a live pane while a playhead moves, rebuilding only for a moving playhead (omnibus15)' do
      pane = ui.panes.fetch(:preview)
      draw(:preview, snap, {}, w: 50, h: 10)
      expect(MB::Sound::UI::PaneRates.priority_of(:preview, pane)).to eq(:list) # (a filter's response)

      now = 0.0
      MB::Sound::UI::Panes::Preview.clock = -> { now }
      env = snap.with(slow: snap.slow.with(inspector: ui_fake_envelope_inspector))
      state = {}
      draw(:preview, env, state, w: 50, h: 10)
      expect(MB::Sound::UI::PaneRates.priority_of(:preview, pane)).to eq(:live)
      first = state[:chart]
      now = 1 / 60.0
      draw(:preview, env, state, w: 50, h: 10)
      expect(state[:chart]).not_to equal(first) # (the playhead moved a frame)

      held = ui_fake_envelope_inspector
      sus = held.with(nodes: [*held.nodes[0...-1], held.nodes[-1].with(live: { stage: :sustain, segment: 2, position: 0.0, peak: 0.7, at: 0.0 }.freeze)].freeze)
      sus_snap = snap.with(slow: snap.slow.with(inspector: sus))
      draw(:preview, sus_snap, state, w: 50, h: 10)
      chart = state[:chart]
      now = 2.0
      draw(:preview, sus_snap, state, w: 50, h: 10)
      expect(state[:chart]).to equal(chart) # (a held sustain doesn't rebuild)
      expect(MB::Sound::UI::PaneRates.priority_of(:preview, pane)).to eq(:live)
    ensure
      MB::Sound::UI::Panes::Preview.clock = nil
    end

    it 'shows no node class names in any sound pane, only DSL names and roles (omnibus15)' do
      env = snap.with(slow: snap.slow.with(inspector: ui_fake_envelope_inspector))
      text = sound_text(env) { |i| env.with(slow: env.slow.with(inspector: env.inspector.with(node: i))) }
      expect(text).to include('lp4  filter ×2', 'saw  osc ×6')
      expect_no_class_names(text)
    end

    it 'lists the inspector\'s keys from its keymap and the planned ones, and the CUE line' do
      built, planned = ui::Panes::SoundKeys.rows
      expect(built.map(&:first)).to include('Up Down', 'Left Right', 'Enter', '0', 'm', 't T', 'n N')
      expect(planned.map(&:first)).to include('/', 'a', 'S')
      expect(draw(:sound_keys, snap, w: 50).join("\n")).to include('Enter      type a value', '(later)')
      cue = snap.with(parts: [ui::PartLoad.new(name: :"acid/cue", kind: :player, state: :playing, load: 0.0)].freeze)
      expect(draw(:audition, cue, w: 90)[0]).to include('CUE ● acid')
    end
  end

  describe 'with a real Session' do
    before do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.instance_eval do
          knob :cut, 2400.hz, range: 150.hz..8000.hz
          track(:bass) { |c| preset :dnb_reese, midi: c, cutoff: :cut }
          bg :bass, seq(MB::Sound::E1, MB::Sound::G1).n8.loop
          bg :pad, 220.hz.saw.at(-30.db).filter(:lowpass, cutoff: knob(:cut), quality: 2)
        end
      end
      4.times { @session.process_buffer }
    end

    after do
      @poll&.close
      @session&.close
      MB::Sound.rewind # (the Session runs on the shared transport)
    end

    def live_snap
      @poll ||= ui::Poll.new(@session)
      feed = (@feed ||= ui::Feed.new.tap { |f| f.needs = [:inspect]; @session.ui_feed = f })
      2.times { @session.process_buffer }
      slow, refs = @poll.call(feed.needs)
      feed.knob_refs = refs
      feed.slow = slow
      feed.take
      @session.process_buffer
      feed.take.with(slow: slow)
    end

    it 'gathers a track\'s knobs, nodes, and code from its graph, frozen, cached per graph, without the render lock' do
      g = ui::Inspect::Gatherer.new
      expect(@session).not_to receive(:players)
      expect(@session).not_to receive(:debug_graphs)
      info = g.call(@session, { track: :bass })
      expect(info.tracks).to eq(%i[bass pad])
      expect(info.knobs).to eq([:cut])
      labels = info.nodes.map(&:label)
      expect(labels).to include('lp4', 'highpass', 'softclip')
      lp4 = info.nodes.find { |n| n.label == 'lp4' }
      expect(lp4.knobs).to eq([:cut]) # (read through knob(:cut) * lfo)
      expect(info.nodes.first).to eq(lp4) # (knob readers first)
      expect(info.selected.preview).to eq(true) # (by default the first node with a preview)
      expect(info.code).to include('synth(', 'knob(:cut)')
      expect(Ractor.shareable?(info)).to eq(true)
      # Without a target: the clip matrix's track, else the first player
      expect(g.call(@session, nil).track).to eq(:bass)
      ui::Panes::Clips.selected = [:pad, nil].freeze
      expect(g.call(@session, nil).track).to eq(:pad)
      expect(g.call(@session, { track: :bass }).track).to eq(:bass) # (a picked track wins)
      ui::Panes::Clips.selected = nil
      again = g.call(@session, { track: :bass })
      expect(again.code).to equal(info.code) # (the node list and code: once per graph)
      expect(again.nodes.reject.with_index { |_, i| i == again.node }).to eq(info.nodes.reject.with_index { |_, i| i == info.node })
    end

    it 'shows no node class names in any sound pane for the dnb_reese preset (omnibus15)' do
      ui::Inspect.target = { track: :bass, node: nil }
      first = live_snap
      expect(first.inspector.nodes.map(&:label)).to include('lp4', 'highpass', 'saw')
      text = sound_text(first) { |i|
        ui::Inspect.target = { track: :bass, node: i }
        live_snap
      }
      expect_no_class_names(text)
    end

    it 'gathers only while a pane needs it, following turned knobs in the picked node\'s preview' do
      poll = ui::Poll.new(@session)
      expect(poll.call.first.inspector).to be_nil
      ui::Inspect.target = { track: :pad, node: nil }
      info = poll.call([:inspect]).first.inspector
      expect(info.track).to eq(:pad)
      expect(info.selected.label).to eq('lowpass')
      expect(info.selected.params.preview[:cutoff]).to be_within(1e-6).of(2400)
      MB::Sound::Session.with_context(session: @session) { MB::Sound.turn(:cut, 4000) }
      6.times { @session.process_buffer }
      expect(poll.call([:inspect]).first.inspector.selected.params.preview[:cutoff]).to be_within(1).of(4000)
    ensure
      poll&.close
    end

    it 'runs its keys\' lines journaled and undoable, and a held key as one line' do
      ui::Inspect.target = { track: :pad, node: nil }
      st = { title_in_rule: true, mode: true }
      s = live_snap
      expect(draw(:inspector, s, st).join("\n")).to include('pad', 'cut', '2400 Hz', '150..8000 exp')
      cut = @session.knobs[:cut]

      # Typed: Enter's Ask, then the typed Ruby as one turn line
      ask = key(:inspector, st, :ask).last
      expect(ask.prompt).to eq('turn :cut, ')
      ui.run_line(key(:inspector, st, :typed, '3000.hz').code, @session)
      4.times { @session.process_buffer }
      expect(cut.value).to be_within(1e-6).of(3000)
      kinds = @session.journal.changes.map(&:kind)
      expect(kinds.count(:turn)).to eq(1)
      MB::Sound::Session.with_context(session: @session) { MB::Sound.undo(on: :now) }
      4.times { @session.process_buffer }
      expect(cut.value).to be_within(1e-6).of(2400)

      # Held: Previews move the knob live, one Commit line journals it
      s = live_snap
      draw(:inspector, s, st)
      now = 100.0
      ui::Panes::Inspector.clock = -> { now }
      3.times do
        r = key(:inspector, st, :turn, ui::KnobTurns::STEP).last
        @session.preview_turn(r.knob, r.value) # (as Tiles#pane_result does)
        now += 0.05
        @session.process_buffer
      end
      expect(cut.value).to be > 2400
      before = @session.journal.changes.count { |e| e.kind == :turn }
      now += ui::TurnGesture::GAP + 0.01
      commit = ui.panes.fetch(:inspector).key_tick(st)
      expect(commit).to be_a(ui::PaneKeys::Commit)
      ui.run_line(@session.gesture_line(commit.knob), @session)
      ui.panes.fetch(:inspector).lines_ran(st)
      expect(@session.journal.changes.count { |e| e.kind == :turn }).to eq(before + 1)
    ensure
      ui::Panes::Inspector.clock = nil
    end
  end

  describe 'on a screen' do
    after do
      @tiles&.stop
      @term&.close
      @session&.close
      MB::Sound.rewind
    end

    it 'goes into the inspector with NAV d, names Enter\'s action, and turns a typed value through the prompt line' do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.instance_eval do
          knob :cut, 2400.hz, range: 150.hz..8000.hz
          bg :pad, 220.hz.saw.at(-30.db).filter(:lowpass, cutoff: knob(:cut))
        end
      end
      4.times { @session.process_buffer }
      @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, session: @session)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.005; end }
      expect(@term.wait_for('t> ')).to eq(true)
      expect(@term.wait_for('2400 Hz')).to eq(true), @term.text
      @term.write("\x1d")
      expect(@term.wait_for(' NAV ')).to eq(true)
      @term.type('d')
      expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :inspector }).to eq(true)
      expect(@term.wait_for("Enter: type cut's value")).to eq(true), @term.lines.last
      @term.write("\r")
      expect(@term.wait_for('turn :cut, 2400')).to eq(true), @term.lines.last
      @term.write("\x15") # Ctrl-U: the line's text goes
      @term.type("3100.hz\r")
      expect(@term.wait_for('turn :cut, 3100.hz')).to eq(true), @term.text
      expect(wait_until { (@session.knobs[:cut].value - 3100).abs < 1e-6 }).to eq(true)
      expect(@session.journal.changes.map(&:kind)).to include(:turn)
      expect(wait_until { @tiles.router.mode == :pane }).to eq(true) # (back in the inspector)
      # Esc on the prompt cancels
      @term.write("\r")
      expect(@term.wait_for('turn :cut, 3100')).to eq(true)
      @term.write("\e")
      expect(@term.wait_for('cancelled')).to eq(true), @term.lines.last
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
    end
  end
end
