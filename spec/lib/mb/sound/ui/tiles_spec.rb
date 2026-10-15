require_relative '../../../../support/ui_helpers'

# The tiled console, headless: a FakeTerminal (a pty read by a UI::VT) is
# the terminal, and the REPL is a real Pry and Reline on the screen's own
# pty (in a thread here; the console adopts its main-thread Pry instead).
RSpec.describe(MB::Sound::UI::Tiles, :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
  end

  def start(layout = :tiles, **opts)
    @tiles, @term = ui_tiles(layout, **opts)
    expect(@term.wait_for('t> ')).to eq(true), @term.text
  end

  def nav(keys)
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type(keys)
  end

  def repl_rect = @tiles.tiler.rects[:repl]

  # The text of +rect+ (default: the REPL pane) on the fake terminal and in
  # the screen's grid (scope panes write their own bytes, so whole screens
  # differ there).
  def region(text, rect = repl_rect)
    text.lines.map(&:chomp)[rect.y, rect.h].map { |l| l[rect.x, rect.w] }
  end

  def expect_same_screen
    @term.settle
    expect(region(@term.text)).to eq(region(@tiles.to_text))
    status = @tiles.rows - 1
    expect(@term.lines[status]).to eq(@tiles.to_text.lines[status].chomp)
  end

  it 'owns the alternate screen, runs Pry in the REPL pane, and gives the terminal back' do
    mode = @term&.slave&.console_mode
    start
    term = @term
    expect(term.vt.alt?).to eq(true)
    expect(term.text).to include('TRACKS', 'MASTER', ' REPL ')
    term.type("6 * 7\r")
    expect(term.wait_for('=> 42')).to eq(true)
    r = repl_rect
    row = term.lines.index { |l| l.include?('=> 42') }
    expect(term.lines[row][r.x, 5]).to eq('=> 42')

    # The cursor sits after the prompt in the REPL pane
    term.settle
    expect([term.vt.row, term.vt.col]).to eq([r.y + 2, r.x + 3])

    # What the terminal shows is exactly the screen's grid (diffed frames add up)
    expect_same_screen

    before = term.slave.console_mode
    @tiles.stop
    term.settle
    expect(term.vt.alt?).to eq(false)
    expect(term.vt.cursor_visible?).to eq(true)
    expect(term.slave.console_mode.to_s).not_to eq(before.to_s) if mode.nil?
  end

  it 'enters NAV with Ctrl-], picks, zooms, and leaves with i, keys going back to the REPL' do
    start
    nav('z')
    expect(@term.wait_for('(zoomed)')).to eq(true)
    expect(@tiles.tiler.rects.keys).to eq([:repl])
    expect(@tiles.host.size).to eq([29, 100]) # the whole screen but the status line
    @term.type('z4')
    expect(@term.wait_for(/ 4 \w+ /)).to eq(true)
    @term.type('i')
    expect(@term.wait_for(' REPL ')).to eq(true)
    @term.type("1 + 2\r")
    expect(@term.wait_for('=> 3')).to eq(true)
  end

  it 'splits, shows a pane in the new slot from the palette, resizes to the cell, and undoes' do
    start
    w = repl_rect.w
    nav('v')
    expect(@term.wait_for('an empty slot')).to eq(true)
    expect(@tiles.tiler.focus).to eq(:empty1)
    @term.type(":show :knobs\r")
    expect(@term.wait_for('KNOBS')).to eq(true)
    expect(@tiles.tiler.layout.panes).to include(:knobs)
    @term.type('1') # transport is pane 1 (reading order); back to the REPL with h/l
    @tiles.act(MB::Sound::UI::Input::Action.of(:focus_index, @tiles.tiler.numbered.index(:repl) + 1))
    before = repl_rect.w
    @term.write("\e[C\e[C\e[1;2C") # right, right, shift-right: 7 cells
    @term.settle
    expect(repl_rect.w).to eq(before + 7)
    expect(@tiles.host.size[1]).to eq(before + 7)
    expect(@tiles.layout.to_ruby).to match(/weight: \d+/)
    @term.type('uuuuu')
    @term.settle
    expect(@tiles.tiler.layout).to eq(MB::Sound::UI.tile_layouts[:tiles])
    expect(repl_rect.w).to eq(w)
  end

  it 'takes multi-line input, Tab completion, bracketed pastes, and Ctrl-C' do
    start
    @term.type("def spec_tiles_x\r42\rend\r")
    expect(@term.wait_for('=> :spec_tiles_x')).to eq(true)
    @term.type("spec_tiles_\t")
    expect(@term.wait_for('t> spec_tiles_x')).to eq(true)
    @term.type("\r")
    expect(@term.wait_for(/=> 42 /)).to eq(true)
    @term.write("\e[200~[1,\r 2].sum\e[201~")
    @term.type("\r")
    expect(@term.wait_for('=> 3')).to eq(true)
    @term.type("sleep 20\r")
    sleep 0.3
    @term.write("\x03")
    expect(@term.wait_for('Interrupt')).to eq(true)
    @term.type("7 * 3\r")
    expect(@term.wait_for('=> 21')).to eq(true)
  end

  it 'keeps a scrollback: scrolls back, searches, and returns to the live view' do
    start
    @term.type("pry_instance.output.puts((0...200).map { |i| \"row \#{i}\" })\r")
    expect(@term.wait_for('row 199')).to eq(true)
    nav('g')
    expect(@term.wait_for(/lines up/)).to eq(true)
    expect(@term.wait_for(/\brow 0\b/)).to eq(true)
    @term.type('/row 150')
    expect(@term.wait_for('/row 150')).to eq(true)
    @term.type("\r")
    @term.settle
    expect(@tiles.scroll).to be > 0
    expect(@term.text).to match(/\brow 150\b/)
    @term.type('G')
    @term.settle
    expect(@tiles.scroll).to eq(0)
    expect(@term.text).to include('row 199')
    expect(@tiles.copy).to include('row 199')
  end

  it 'follows the terminal size' do
    start(rows: 24, cols: 80)
    @term.resize(30, 110)
    @term.settle
    expect(@term.wait_for(/ REPL /)).to eq(true)
    expect(@tiles.rows).to eq(30)
    expect(@tiles.cols).to eq(110)
    expect(@tiles.host.size).to eq([repl_rect.h, repl_rect.w])
    expect_same_screen
  end

  it 'evaluates palette lines in the console binding and shows the result' do
    start
    nav(':')
    @term.type("[6, 7].reduce(:*)\r")
    expect(@term.wait_for('=> 42')).to eq(true)
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type(":nosuch_thing_xyz\r")
    expect(@term.wait_for('NameError')).to eq(true)
  end

  it 'enters NAV with a lone Esc only when nav_esc is set, sending Esc and a quick key to the REPL' do
    start(nav_esc: 0.2)
    @term.write("\e")
    expect(@term.wait_for(' NAV ', timeout: 2)).to eq(true)
    @term.type('i')
    expect(@term.wait_for(' REPL ')).to eq(true)
    @term.type('abc')
    @term.write("\eb") # Alt-b (one read): back a word in Reline
    @term.type("x\r")
    expect(@term.wait_for(/xabc/)).to eq(true)
    expect(@tiles.router.mode).to eq(:repl)
  end

  it 'maps MIDI notes and controllers to the same actions' do
    start
    @tiles.on(36, :zoom).on_cc(21, [:tab, 1])
    @tiles.router.midi(:note, 36, 0.8)
    expect(@tiles.tiler.layout.zoom).to eq(:repl)
    calls = []
    @tiles.on(37) { calls << :hit; :ok }
    @tiles.router.midi(:note, 37, 1.0)
    @tiles.router.midi(:note, 37, 0.0) # note-off: nothing
    expect(calls).to eq([:hit])
  end

  it "reads ui.on bindings from the Session's MIDI log" do
    ev = MB::Sound::MIDI::Event
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    events = [ev.parse([0x90, 36, 100], time: 0.01r), ev.parse([0x80, 36, 0], time: 0.05r), ev.parse([0xb0, 21, 127], time: 0.06r)]
    session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
    start(session: session)
    @tiles.on(36, :zoom).on_cc(21, [:split, :rows])
    sleep 0.1 # the painter has seen the (empty) log
    10.times { session.process_buffer(800) }
    deadline = MB::U.clock_now + 3
    sleep 0.02 until @tiles.tiler.layout.panes.include?(:empty1) || MB::U.clock_now > deadline
    expect(@tiles.tiler.layout.panes).to include(:empty1)
    expect(@tiles.tiler.layout.zoom).to be_nil # the split ended the zoom the pad started
    expect(@tiles.tiler.undo?).to eq(true)
  ensure
    session&.close
  end
end
