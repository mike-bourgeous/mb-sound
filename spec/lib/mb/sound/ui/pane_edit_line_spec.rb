require_relative '../../../../support/ui_helpers'

# e in the panes' modes (ui-phase1-1, the 2026-11-21 plan's Phase 1 item
# 7): the console line the picked row's main action would run, onto the
# REPL's prompt unrun (PaneKeys#key_edit_line, one implementation; each
# pane only says which line is its row's).
RSpec.describe('UI pane e: the row\'s line onto the console', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:paste) { ui::PaneKeys::Paste }

  def paint(name, snap, state, w: 60, h: 10)
    grid = MB::Term::Cells.new(w, h)
    ui.panes.fetch(name).draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state.merge!(title_in_rule: true, mode: true))
    state
  end

  def edit(name, state) = ui.panes.fetch(name).key_action(:edit_line, state)

  # The panes whose modes bind e to the shared action, and the ones that
  # keep e for something of their own or have no rows (with why).
  BOUND = %i[form tracks knobs queue lane buses clips racks].freeze
  OWN_E = {
    picker: 'e is its own edit (the action\'s line), the same idea first',
    tuner: 'e is its own edit (the line onto the console), the same idea first',
  }.freeze

  it 'binds e to the shared action in the panes with rows and a main action' do
    BOUND.each do |name|
      km = ui.panes.fetch(name).mode_keymap.entries
      b = km.find { |x| x.chord == ['e', []] }
      expect(b&.action).to eq(:edit_line), name.inspect
      expect(b.help).to eq(ui::PaneKeys::EDIT_HELP)
    end
    OWN_E.each_key { |name| expect(ui::Panes.const_get(name.capitalize).mode_keymap.entries.find { |x| x.chord == ['e', []] }&.action).to eq(:edit), name.inspect }
  end

  it 'gives each pane\'s main line for the picked row, or says why there is none' do
    snap = ui_fake_snapshot.with(bus_levels: nil, send_levels: nil)
    form = snap.with(slow: snap.slow.with(form: snap.slow.form.with(sections: [[:drop, '8 bars'], [:break, '4 bars']].map(&:freeze).freeze)))
    expect(edit(:form, paint(:form, form, {}))).to eq(paste['goto :drop', 'on the console line: edit it, Enter runs it'])

    tracks = snap.with(slow: snap.slow.with(tracks: [ui::TrackInfo.new(name: :t1, q: '1', clip: 'c', armed: false)].freeze)).with(parts: [ui::PartLoad.new(name: :t1, kind: :player, state: :playing, load: 0.0)].freeze)
    st = paint(:tracks, tracks, {})
    expect(edit(:tracks, st)).to start_with('pick a track first')
    st[:cursor] = :t1
    expect(edit(:tracks, st).code).to eq('stop :t1')
    expect(st[:stopped_here]).to be_nil # (no bookkeeping: nothing ran)

    expect(edit(:queue, paint(:queue, snap, {})).code).to eq('cancel queued: :cut, kind: :knob')
    expect(edit(:lane, paint(:lane, snap, {})).code).to eq('cancel queued: :cut, kind: :knob')

    st = paint(:buses, snap, {})
    expect(edit(:buses, st)).to start_with('pick a bus or a send first')
    ui.panes.fetch(:buses).key_action(:pick, st, 1)
    expect(edit(:buses, st).code).to eq('mute :verb')
    ui.panes.fetch(:buses).key_action(:pick, st, 1)
    expect(edit(:buses, st).code).to eq('feed :pad, :verb, -12.04.db')

    expect(edit(:knobs, paint(:knobs, snap.with(knobs: [].freeze), {}))).to start_with('no knobs')
    expect(edit(:clips, paint(:clips, snap, {})).code).to match(/\A(launch :\w+, \d+|stop :\w+)\z/) # (the cursor's first cell)
  end

  describe 'on a screen' do
    after do
      @tiles&.stop
      @term&.close
      @session&.close
      MB::Sound.rewind
    end

    it 'puts the picked track\'s line on the console prompt, unrun, and goes to the console' do
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      expect { MB::Sound::Session.with_context(session: @session) { MB::Sound.demo(:night_bus); MB::Sound.go(:groove, on: :now) } }.to output(/night_bus/).to_stdout
      8.times { @session.process_buffer }
      @tiles, @term = ui_tiles(:session, rows: 60, cols: 236, session: @session)
      @tiles.show(:tracks, at: :repl) unless @tiles.tiler.layout.panes.include?(:tracks)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.004; end }
      @tiles.enter(:tracks)
      st = @tiles.instance_variable_get(:@states)[:tracks]
      expect(wait_until { st[:names]&.include?(:drums) && @tiles.router.mode == :pane }).to eq(true)
      @term.write("\e[B")
      expect(wait_until { st[:cursor] }).to eq(:drums)
      @term.type('e')
      expect(wait_until { @tiles.router.mode == :repl }).to eq(true), @tiles.router.mode.inspect
      expect(@term.wait_for('stop :drums')).to eq(true), @term.lines.last(3).join("\n")
      expect(@session.players.key?(:drums)).to eq(true) # (not run)
      expect(@session.journal.changes.none? { |e| e.kind == :stop && e.subject == :drums }).to eq(true)
    ensure
      stop = true
      pump&.join
    end
  end
end
