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
    grid = MB::Term::Cells.new(w, h)
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
      # (the inspector's other views: the panel, every node as chips)
      [{ view: :panel }, { plumbing: true }].each { |st| texts << draw(:inspector, s, { title_in_rule: true, **st }, w: 100, h: 30).join("\n") }
      texts << key(:inspector, { snap: s }, :node, 1).to_s if info
    end
    texts.join("\n")
  end

  def expect_no_class_names(text)
    found = node_class_names.select { |n| text.match?(/\b#{n}\b/) }
    expect(found).to eq([]), "class names in the sound panes: #{found.join(', ')}\n#{text.lines.grep(/\b(#{found.join('|')})\b/).first(5).join}"
  end

  describe 'the panes with fake data' do
    it 'draws the track\'s voice in sections, the picked row open with its params, knobs on the params they drive (sound-design-nav-1)' do
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      lines = draw(:inspector, lp4, { title_in_rule: true, mode: true }, w: 60, h: 14)
      text = lines.join("\n")
      expect(lines[0]).to start_with('bass  2/3').and include('s f a o x')
      expect(text).to include(' SOURCE  s', '▸FILTER  f', ' AMP  a', ' FX  x', '▸lp4', 'stereo  cut 2400 Hz  reso 0.25')
      expect(text).to match(/cutoff +█+.* 2400 Hz  cut/) # (the knob's meter on the param it drives)
      expect(text).to include('resonance  0.25  ·') # (a literal: dim, Enter offers its bind)
      expect(text).to include('saw ×6', 'highpass ×2', '61 plumbing nodes hidden (p shows)')
      expect(lines.index { |l| l.match?(/\A[ ▸]SOURCE/) }).to be < lines.index { |l| l.match?(/\A[ ▸]FILTER/) }
      # Every row open when they all fit; the picked one alone, others on one line, when short
      tall = draw(:inspector, lp4, { title_in_rule: true }, w: 60, h: 30).join("\n")
      expect(tall).to include('  cutoff     150 Hz') # (highpass's params too)
      short = draw(:inspector, lp4, { title_in_rule: true }, w: 60, h: 8)
      expect(short.join("\n")).to include('▸lp4', 'cutoff')
      expect(short.grep(/\A (SOURCE|AMP|FX) +\S/).length).to be >= 2
      keyed = draw(:inspector, lp4, { title_in_rule: true, mode: true }, w: 60, h: 8)
      expect(keyed.grep(/\A (SOURCE|AMP|FX)  [safox] +\S/).length).to be >= 2
      empty = snap.with(slow: snap.slow.with(inspector: nil))
      expect(draw(:inspector, empty)[0]).to include('nothing to inspect')
    end

    it 'draws the signal chain on one line over the sections when there is room, the amp where the amp envelope is' do
      env = snap.with(slow: snap.slow.with(inspector: ui_fake_envelope_inspector))
      lines = draw(:inspector, env, { title_in_rule: true }, w: 80, h: 20)
      expect(lines[1]).to eq('notes → saw ×6 → lp4 → softclip → amp → highpass ×2 → out')
      expect(draw(:inspector, env, { title_in_rule: true }, w: 80, h: 12)[1]).not_to start_with('notes') # (short: the sections only)
    end

    # (ux-notes-1, the maintainer, 2026-10-31: "Pressing up when at the top
    # of an inspector list should move to the bottom of the list above,
    # e.g. glide time up to osc2"; inspector-nav-1, 2026-11-02: "sometimes
    # it takes me to the next section, sometimes loops in one section,
    # sometimes gets stuck at the end of one section.  Doesn't loop around
    # from very top to very bottom")
    it 'steps Up past a row\'s first param into the row above\'s last, Down back, wrapping at the ends, before the next poll too' do
      pane = ui.panes.fetch(:inspector)
      info = snap.inspector
      rows = pane.send(:section_rows, info)
      skip 'the fake data needs two rows' if rows.length < 2
      st = { title_in_rule: true, mode: true }
      picked = ->(j) { snap.with(slow: snap.slow.with(inspector: info.with(node: j))) }
      draw(:inspector, picked.(rows[1]), st, w: 80, h: 30)
      list = pane.send(:pick_list, st, info)
      first1 = list.index { |e| e[3] == rows[1] }
      expect(st[:pick]).to eq(first1) # (the shown row's first stop)
      key(:inspector, st, :pick, -1)
      expect(MB::Sound::UI::Inspect.target[:node]).to eq(rows[0])
      expect(st[:at][2]).to eq(rows[0])
      expect(list[first1 - 1][3]).to eq(rows[0]) # (its last stop)
      expect(st[:pick]).to eq(first1 - 1)
      # (drawn before the poll brings rows[0]'s info: the stop is kept, and drawn open)
      lines = draw(:inspector, picked.(rows[1]), st, w: 80, h: 30)
      expect(st[:pick]).to eq(first1 - 1)
      key(:inspector, st, :pick, 1)
      expect(MB::Sound::UI::Inspect.target[:node]).to eq(rows[1])
      expect(st[:pick]).to eq(first1)
      # Two presses before a poll count from where they are (they looped in the row before)
      key(:inspector, st, :pick, 1)
      key(:inspector, st, :pick, 1)
      expect(st[:pick]).to eq((first1 + 2) % list.length)
      # Wrapping: Up from the very first stop is the very last, Down back
      key(:inspector, st, :pick, -1) until st[:pick] == 0
      key(:inspector, st, :pick, -1)
      expect(st[:pick]).to eq(list.length - 1)
      key(:inspector, st, :pick, 1)
      expect(st[:pick]).to eq(0)
      expect(lines.join("\n")).to include('▸')
    end

    # (ux-notes-2, the maintainer's note 3: "Showing SOURCE s made me want
    # to do ^w, s, but that split the pry panel; maybe subsections need
    # more contrasting colors and should only show shortcuts when
    # focused?"; his "Keys only when focused" + "Contrasting bands")
    it 'draws section headings as colored bands, with their jump keys only while the inspector\'s keys are live' do
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      bg_of = ->(grid, x, y) { grid.instance_variable_get(:@bg)[y * grid.width + x] }
      pack = ->(role) { MB::Term::Cells.pack(ui::Theme.rgb(role)) }
      [[{ title_in_rule: true }, false], [{ title_in_rule: true, mode: true }, true]].each do |state, live|
        [:sections, :panel].each do |view|
          grid = MB::Term::Cells.new(60, 14)
          ui.panes.fetch(:inspector).draw(ui::Canvas.new(grid, 0, 0, 60, 14), lp4, state.merge(view: view))
          lines = grid.to_text(:none).lines.map(&:rstrip)
          y = lines.index { |l| l.match?(/\A▸FILTER/) }
          expect(y).not_to be_nil, "#{view}: #{lines.join("\n")}"
          expect(lines[y]).to eq(live ? '▸FILTER  f' : '▸FILTER'), view.to_s
          # (the band runs across the row, in FILTER's color)
          expect([0, 30, 59].map { |x| bg_of.(grid, x, y) }.uniq).to eq([pack.(:band_filter)]), view.to_s
          next unless view == :sections
          src = lines.index { |l| l.match?(/\A SOURCE/) }
          expect(lines[src]).to eq(live ? ' SOURCE  s' : ' SOURCE')
          expect(bg_of.(grid, 10, src)).to eq(pack.(:band_source))
          expect(lines.join("\n")).not_to match(/SOURCE s|FILTER f|AMP a|FX x/) unless live
        end
      end
      # Every built-in theme has the band colors, the bands' text reading on each
      %i[default paper phosphor mono].each do |theme|
        t = MB::Term::Themes.named(theme)
        expect(%i[band_text band_source band_filter band_amp band_mod band_fx band_knobs] - t.roles.keys).to eq([]), theme.to_s
      end
    end

    it 'draws the front panel with P: knobs and literals as cells by section, the picked row\'s first cell picked' do
      st = { title_in_rule: true, mode: true, view: :panel }
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      lines = draw(:inspector, lp4, st, w: 80, h: 10)
      text = lines.join("\n")
      expect(lines[0]).to include('P sections')
      expect(text).to include('▸FILTER  f')
      expect(text).to match(/cut +█+.*2400 Hz/) # (the knob's cell: meter and value)
      expect(text).to match(/reso +·+ 0.25/) # (a literal's cell: dots, dim)
      expect(text).not_to include('saw', 'phase') # (only knobs and literals)
      pane = ui.panes.fetch(:inspector)
      expect(pane.enter_hint(st)).to eq("type cut's value")
      key(:inspector, st, :pick, 1)
      expect(st[:pick]).to eq(1)
      expect(pane.send(:picked_param, st)[0]).to eq(:resonance)
      # P back, p the chips
      expect(key(:inspector, st, :view)).to eq('sections view (P flips)')
      expect(pane.view(st)).to eq(:sections)
      expect(pane.view({ level: :compact })).to eq(:panel) # (by the screen's size when not flipped)
      expect(key(:inspector, st, :plumbing)).to include('every node')
      expect(pane.view(st)).to eq(:plumbing)
    end

    it 'draws every node as chips with p (the plumbing view, the old list)' do
      text = draw(:inspector, snap, { title_in_rule: true, plumbing: true }).join("\n")
      expect(text).to include('bass  2/3', 'cut', '2400 Hz', '100..8000 exp', 'nodes lp4 highpass×2 softclip saw×6')
      expect(text).to include('highpass  filter ×2  2/4', 'cutoff     150 Hz', 'quality    0.7  Q')
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      expect(draw(:inspector, lp4, { title_in_rule: true, plumbing: true }).join("\n")).to include('cutoff     → knob cut 2400 Hz')
    end

    it 'turns, resets, types, and learns the picked knob as console lines; t, n, and s f a o x pick tracks and rows' do
      st = { title_in_rule: true, mode: true }
      lp4 = snap.with(slow: snap.slow.with(inspector: snap.inspector.with(node: 0)))
      draw(:inspector, lp4, st)
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
      # (rows step in section order from lp4: SOURCE FILTER AMP FX)
      expect(key(:inspector, st, :node, 1)).to eq('AMP softclip (drive)')
      expect(ui::Inspect.target).to eq({ track: :bass, node: 2, voice: nil })
      expect(key(:inspector, st, :node, -1)).to eq('SOURCE saw ×6')
      expect(key(:inspector, st, :section, :amp)).to eq('AMP softclip (drive)')
      expect(ui::Inspect.target).to eq({ track: :bass, node: 2, voice: nil })
      expect(key(:inspector, st, :section, :mod)).to eq('no MOD rows in bass')
      expect(key(:inspector, st, :voice, 1)).to include('no drum voices')

      # Tab and Shift-Tab step through the nodes like n and N
      km = ui::Panes::Inspector.mode_keymap
      expect(km[MB::Term::Input::Key.new(key: :tab, mods: [])]).to eq(km[MB::Term::Input::Key.new(key: 'n', mods: [])])
      expect(km[MB::Term::Input::Key.new(key: :tab, mods: [:shift])]).to eq(km[MB::Term::Input::Key.new(key: 'N', mods: [])])
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
      expect(text).to include('lp4', 'saw ×6', 'FILTER', 'amp_env')
      expect_no_class_names(text)
    end

    it 'lists the inspector\'s keys from its keymap and the planned ones, and the CUE line' do
      built, planned = ui::Panes::SoundKeys.rows
      expect(built.map(&:first)).to include('Up Down', 'Left Right', 'Enter', '0', 'm', 't T', 'n N')
      expect(built.first).to eq(ui::Panes::SoundKeys::PICKER) # (ui-scaffold-1: the library picker's keys in one line)
      expect(planned.map(&:first)).to eq(%w[S b *])
      expect(draw(:sound_keys, snap, w: 50).join("\n")).to include('l          library: / find', 'Enter      type a value')
      expect(draw(:sound_keys, snap, w: 50, h: 30).join("\n")).to include('(later)')
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
      # (:cut, which the patch gives the preset, and the preset's other params as the track's knobs: Arrangement::TrackKnobs)
      expect(info.knobs).to contain_exactly(:cut, :"bass/resonance", :"bass/drive", :"bass/glide")
      labels = info.nodes.map(&:label)
      expect(labels).to include('lp4', 'highpass', 'softclip')
      lp4 = info.nodes.find { |n| n.label == 'lp4' }
      expect(lp4.knobs).to contain_exactly(:cut, :"bass/resonance") # (:cut read through knob(:cut) * lfo)
      expect(lp4.param_knobs).to eq({ cutoff: :cut })
      expect(lp4).to have_attributes(section: :filter, count: 1, channels: 2) # (one stereo lp4 per voice)
      shown = info.nodes.reject { |n| n.section == :plumbing }
      expect(shown.map(&:section).chunk_while { |a, b| a == b }.map(&:first)).to eq(%i[source filter amp mod fx]) # (in section order)
      expect(shown.find { |n| n.what == 'amp env' }).to have_attributes(section: :amp, dest: ['amp'])
      expect(shown.find { |n| n.label == 'lfo' }).to have_attributes(section: :mod, dest: ['lp4 cutoff'])
      expect(shown.find { |n| n.label == 'highpass' }).to have_attributes(section: :fx, what: 'post-amp EQ', count: 2)
      expect(info.selected).to eq(lp4) # (by default the filter)
      expect(info.loose).to eq([]) # (every knob on a row's param)
      expect(info.hidden.values.sum).to be > 100
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

    # gen-knobs-1: a generator's track knobs (:"lead/density") are a notes
    # row's params at the top of SOURCE, not loose knobs.
    it 'shows a library generator\'s track knobs on a notes row' do
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif)
        MB::Sound.level(:lead, -30.db)
        MB::Sound.bg(:lead, on: :now)
      end
      3.times { @session.process_buffer }
      info = ui::Inspect::Gatherer.new.call(@session, { track: :lead })
      notes = info.nodes.find { |n| n.what == 'notes' }
      expect(notes).to have_attributes(label: 'phrygian_motif', section: :source)
      expect(%i[density mutate].map { |p| notes.knob_of(p) }).to eq(%i[lead/density lead/mutate])
      expect(notes.params.values[:density].value).to eq(0.5)
      expect(info.loose).not_to include(:"lead/density", :"lead/mutate")
      expect(info.nodes.reject { |n| n.section == :plumbing }.first).to equal(notes) # (the notes first)
      ui::Inspect.target = { track: :lead, node: info.nodes.index(notes) }
      text = draw(:inspector, live_snap, { title_in_rule: true }, w: 100, h: 30).join("\n")
      expect(text).to include('phrygian_motif', 'density', 'mutate')
      expect_no_class_names(text)
    end

    # The maintainer, 2026-10-30: "Toggle" (a preset's numbers as panel
    # cells; library-2).  Since editability-1 they bind like any track's
    # literals, as the sections view's do (they were read-only cells).
    it 'shows a preset\'s numbers as bindable panel cells while F is on' do
      ui::Inspect.target = { track: :bass, node: nil }
      snap = live_snap
      pane = ui.panes.fetch(:inspector)
      st = { title_in_rule: true, mode: true, view: :panel, snap: snap }
      expect(snap.inspector.document).to eq('dnb_reese')
      plain = pane.send(:pick_list, st, snap.inspector)
      expect(plain.select { |e| e[0] == :param }).to all(satisfy { |e| snap.inspector.nodes[e[3]].knob_of(e[1]) }) # (knob cells only)
      expect(draw(:inspector, snap, st, w: 100, h: 30)[0]).to include('F show numbers')
      expect(key(:inspector, st, :fixed)).to eq("dnb_reese's numbers shown (Enter or Left/Right binds one; F hides them)")
      shown = pane.send(:pick_list, st, snap.inspector)
      numbers = shown - plain
      expect(numbers).not_to be_empty
      expect(numbers).to all(satisfy { |e| e[0] == :param && snap.inspector.nodes[e[3]].knob_of(e[1]).nil? })
      expect(draw(:inspector, snap, st, w: 100, h: 30)[0]).to include('F hide numbers')
      # A number's cell offers its bind, as in the sections view
      # (picking a cell picks its row, whose binds the next snapshot has)
      ui::Inspect.target = { track: :bass, node: numbers.first[3] }
      st[:snap] = snap = live_snap
      list = pane.send(:pick_list, st, snap.inspector)
      st[:pick] = list.index { |e| e[0] == :param && e[1] == numbers.first[1] && e[3] == numbers.first[3] }
      expect(pane.enter_hint(st)).to match(/\Amake \w+ knob :"bass\/\w+": rebuilds bass/)
      st[:pick] = nil
      expect(key(:inspector, st, :fixed)).to eq("dnb_reese's numbers hidden (F shows them)")
      expect(pane.send(:pick_list, st, snap.inspector)).to eq(plain)
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
      expect(draw(:inspector, s, st).join("\n")).to include('pad', 'lowpass', 'cutoff', '2400 Hz  cut')
      expect(draw(:inspector, s, st.merge(plumbing: true)).join("\n")).to include('pad', 'cut', '2400 Hz', '150..8000 exp')
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

    # (inspector-nav-1: his line, keys through the screen's pty as typed,
    # faster than the 4/s poll)
    it 'steps Up and Down through every stop of acid on his line and wraps, on the screen, keys typed faster than the poll' do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      MB::Sound::Session.with_context(session: @session) do
        MB::Sound.module_eval('track :bass, L.inst.acid; bg :bass, seq(E1, E1, G1, A1).n8.loop.legato(0.5)')
      end
      20.times { @session.process_buffer }
      MB::Sound::UI::Inspect.target = { track: :bass }.freeze
      @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, session: @session)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.005; end }
      expect(@term.wait_for('diode')).to eq(true), @term.text
      @term.write("\x1d")
      expect(@term.wait_for(' NAV ')).to eq(true)
      @term.type('d')
      expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :inspector }).to eq(true)
      pane = ui.panes.fetch(:inspector)
      st = @tiles.instance_variable_get(:@states)[:inspector]
      expect(wait_until { st[:at] }).to be_truthy
      list = pane.send(:pick_list, st, st[:snap].inspector)
      start = st[:at]
      # A whole lap down, typed at once after the first: back where it started
      @term.write("\e[B")
      expect(wait_until { st[:at] != start }).to eq(true)
      @term.write("\e[B" * (list.length - 1))
      expect(wait_until { st[:at] == start }).to eq(true), "#{st[:at].inspect} after a lap from #{start.inspect}"
      expect(st[:pick]).to eq(list.index { |e| pane.send(:stop_key, e) == start })
      # SOURCE's first row (saw phase), then Up: the very last stop, on screen
      @term.type('s')
      expect(wait_until { (st[:at] || [])[2] == list.first[3] }).to eq(true), st[:at].inspect
      @term.write("\e[A")
      expect(wait_until { st[:at] == pane.send(:stop_key, list.last) }).to eq(true), st[:at].inspect
      expect(@term.wait_for(list.last[1].to_s)).to eq(true), @term.text
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
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
