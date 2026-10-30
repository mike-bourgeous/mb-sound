require_relative '../../../../support/ui_helpers'

# The library picker of ui :sound (ui-scaffold-1): results through the
# console popup's ranking (Library::Finder) and find's, Enter's likely
# action per entry kind, the pane's keys as console lines, find as you
# type through a live PaneKeys::Ask, a temporary picker on its jump letter
# where the layout lacks one, and a load into a playing track.
RSpec.describe(MB::Sound::UI::Picker, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pane) { ui.panes.fetch(:picker) }

  before do
    ui::Inspect.target = nil
    allow(described_class).to receive(:index).and_return(ui_fake_library)
  end

  after do
    ui::Inspect.target = nil
    @tiles&.stop
    @term&.close
  end

  def entry(name) = ui_fake_library.entries.find { |e| e.name == name }

  def names(head, query) = described_class.results(head, query).map(&:name)

  def draw(snap, state, w: 40, h: 14)
    grid = MB::Term::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid.to_text(:none).lines.map(&:rstrip)
  end

  it 'finds as you type under a head, words narrowing, then by find\'s ranking' do
    expect(described_class.heads).to eq(%i[inst fx kit seq master all])
    expect(names(:inst, '')).to eq(%i[dnb_reese dnb_sub glass_keys init jungle_reese])
    expect(names(:inst, 'ree')).to eq(%i[dnb_reese jungle_reese])
    expect(names(:inst, 'dnb ree')).to eq(%i[dnb_reese]) # (a word, then the letters: L.inst.dnb.ree)
    expect(names(:inst, 'dnb.')).to eq(%i[dnb_reese dnb_sub])
    expect(names(:inst, 'dnb_sub')).to eq(%i[dnb_sub]) # (an exact name)
    expect(names(:fx, 'bright')).to eq(%i[plate])
    expect(names(:all, 'hall')).to eq(%i[hall])
    expect(names(:inst, 'zzz')).to eq([])
    expect(names(:inst, 'walking')).to eq([]) # (a clip's tag: not an instrument)
  end

  it 'names the likely action per kind: a load into the track, an audition, a line to edit' do
    a = described_class.action(entry(:dnb_reese), track: :bass, patch: true)
    expect(a).to have_attributes(kind: :run, code: 'track :bass, L.inst.dnb_reese')
    expect(a.note).to start_with('bass plays dnb_reese from its launch point')
    expect(described_class.action(entry(:tr909), track: :drums, patch: true).code).to eq('track :drums, L.kit.tr909')
    expect(described_class.action(entry(:dnb_reese), track: nil)).to have_attributes(kind: :audition, code: 'audition L.inst.dnb_reese')
    expect(described_class.action(entry(:dnb_reese), track: :pad, patch: false)).to have_attributes(kind: :paste, code: 'track :pad, L.inst.dnb_reese; bg :pad, clip')
    expect(described_class.action(entry(:hall), track: :bass)).to have_attributes(kind: :paste, code: 'bus(:hall) { |sig| sig.then(&L.fx.hall) }; feed :bass, :hall, -12.db')
    expect(described_class.action(entry(:walk_a), track: :bass)).to have_attributes(kind: :run, code: 'bg :bass, L.seq.walk_a.()')
    expect(described_class.action(entry(:club), track: :bass)).to have_attributes(kind: :paste, code: 'master :club')
  end

  it 'draws the heads, the track\'s instrument, and the picked entry\'s details; its keys return console lines' do
    snap = ui_fake_snapshot
    st = { mode: true }
    text = draw(snap, st).join("\n")
    expect(text).to include('inst fx kit seq master', '→ bass', '▸●dnb_reese', 'jungle_reese', 'A detuned saw Reese', 'params cutoff', 'L.inst.dnb_reese')
    expect(pane.enter_hint(st)).to start_with('bass plays dnb_reese from its launch point')

    run = pane.key_action(:act, st)
    expect(run).to eq(ui::PaneKeys::Run['track :bass, L.inst.dnb_reese', pane.enter_hint(st)])
    pane.key_action(:pick, st, 1)
    expect(pane.key_action(:audition, st)).to eq(ui::PaneKeys::Run['audition L.inst.dnb_sub', 'audition dnb_sub on MAIN at -6 dB'])
    playing = snap.with(parts: [ui::PartLoad.new(name: :audition, kind: :player, state: :playing, load: 0.0)].freeze)
    draw(playing, st)
    expect(pane.key_action(:audition, st).code).to eq('audition off') # (again: stop)
    expect(pane.key_action(:edit, st)).to be_a(ui::PaneKeys::Paste).and(have_attributes(code: 'track :bass, L.inst.dnb_sub'))

    expect(pane.key_action(:head, st, 1)).to eq('L.fx: 3 entries')
    expect(draw(snap, st).join("\n")).to include('hall', 'juno1', 'reverb')
    expect(pane.key_action(:head, st, -2)).to eq('L.all: 11 entries')
    pane.key_action(:head, st, 1)

    ask = pane.key_action(:find, st)
    expect(ask).to eq(ui::PaneKeys::Ask['find: ', '', :found, changed: :finding])
    pane.key_action(:finding, st, 'jun')
    expect(draw(snap, st).join("\n")).to include('find jun▏', 'jungle_reese')
    expect(pane.key_action(:found, st, 'jun')).to eq('1 match under L.inst')
    pane.key_action(:unfind, st)
    expect(st[:query]).to eq('ju')
    expect(pane.key_action(:quit, st)).to eq(:close)
  end

  # The picker at 80x24 (ui :sound's compact layout lacks it): NAV l puts
  # it in for a while and goes in, / finds as each letter is typed, Esc
  # puts the find back, q takes it away with the layout as it was.
  it 'comes in for a while on its jump letter, finding as each letter is typed' do
    @term = UIHelpers::FakeTerminal.new(24, 80)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:sound), input: @term.slave, output: @term.slave, repl: :none,
                           probe: false, size: [24, 80], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @tiles.start(thread: false)
    @tiles.refresh(0.0)
    before = @tiles.tiler.layout
    expect(before.panes).not_to include(:picker)
    feed = ->(bytes) { @term.write(bytes); 10.times { @tiles.pump(0.01) }; @tiles.refresh(0.0) }

    @tiles.jump(:picker)
    @tiles.refresh(0.0)
    expect(@tiles.tiler.layout.panes).to include(:picker, :inspector)
    expect(@tiles.tiler.focus).to eq(:picker)
    expect(@tiles.to_text).to include('LIBRARY', 'dnb_reese')

    feed.('/')
    feed.('ree')
    st = @tiles.instance_variable_get(:@states)[:picker]
    expect(st[:query]).to eq('ree')
    expect(@tiles.to_text).to include('jungle_reese').and(include('find: ree'))
    expect(@tiles.to_text).not_to include('glass_keys')
    feed.("\e")
    15.times { @tiles.pump(0.02) }
    expect(st[:query]).to eq('') # (Esc: the find as it was)
    feed.('q')
    expect(@tiles.tiler.layout).to eq(before)
  end

  # e on a real console (Pry on the tiles' pty): the action's line typed
  # onto the REPL's prompt, not run, and the screen back in REPL mode
  it 'puts the action\'s line on the console to edit (e)' do
    @tiles, @term = ui_tiles(:sound, rows: 40, cols: 120, source: -> { ui_fake_snapshot.with(slow: ui_fake_snapshot.slow.with(inspector: nil)) })
    expect(wait_until { @term.text.include?('t> ') }).to be_truthy
    @tiles.jump(:picker)
    expect(wait_mode(@tiles, :pane)).to eq(true)
    @term.write('e')
    expect(wait_mode(@tiles, :repl)).to eq(true)
    expect(wait_until { @term.text.include?('t> audition L.inst.dnb_reese') }).to be_truthy # (nothing inspected: Enter's action auditions)
    expect(@term.text).not_to include('=> #<audition') # (typed, not run)
  end

  # A load from the picker on a real Session (the shipped library): the
  # Enter line runs through UI.run_line as a console line would, the
  # instrument changes at the track's launch point, one undo step.
  it 'loads the picked instrument into the playing inspected track, journaled and undoable' do
    allow(described_class).to receive(:index).and_call_original
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    poll = ui::Poll.new(session)
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.track(:bass, :dnb_sub)
      MB::Sound.bg(:bass, MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop)
    end
    4.times { session.process_buffer }
    ui::Inspect.target = { track: :bass, node: nil }
    slow, = poll.call([:inspect])
    snap = ui_fake_snapshot.with(slow: slow)
    st = { mode: true }
    draw(snap, st)
    pane.key_action(:finding, st, 'dnb_reese')
    run = pane.key_action(:act, st)
    expect(run.code).to eq('track :bass, L.inst.dnb_reese')
    ui.run_line(run.code, session)
    # (the new graph and its knob's value land together at the next bar)
    expect(session.journal.changes.last(2).map(&:to_s)).to eq(['bg :bass lands 2:1 (queued)', 'turn :"bass/cutoff" lands 2:1 (queued)'])
    200.times { session.process_buffer }
    expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(session.arrangement.tracks[:bass].patch).name).to eq(:dnb_reese)
    expect(session.knobs[:"bass/cutoff"].value).to eq(2400.0) # (dnb_sub's untouched 110 Hz: dnb_reese's own)
    slow, = poll.call([:inspect])
    expect(slow.tracks.find { |t| t.name == :bass }.instrument.name).to eq(:dnb_reese)
    MB::Sound::Session.with_context(session: session) { MB::Sound.undo(on: :now) }
    4.times { session.process_buffer }
    expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(session.arrangement.tracks[:bass].patch).name).to eq(:dnb_sub)
  ensure
    poll&.close
    session&.close
    MB::Sound.rewind
  end
end
