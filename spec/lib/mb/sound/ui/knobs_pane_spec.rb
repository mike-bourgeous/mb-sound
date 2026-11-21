require_relative '../../../../support/ui_helpers'

# The knobs pane's own mode (knobs-pane-keys-1, the maintainer: "I expect
# the knobs pane to let me turn the knobs with the keyboard"): the racks
# pane's knob keys through the same UI::KnobTurns.  Keys return lines
# (PaneKeys::Turn, Preview, Commit, Ask) the screen runs; outside the mode
# the pane draws exactly as before.
RSpec.describe('the knobs pane', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:pk) { ui::PaneKeys }
  let(:pane) { ui.panes.fetch(:knobs) }
  let(:snap) { ui_fake_snapshot(rack_knobs: true) } # (cut, drive, bass/dub/space, bass/dub/tone)

  def grid_of(snap, state, w: 40, h: 6)
    state[:title_in_rule] = true
    grid = MB::Term::Cells.new(w, h)
    pane.draw(ui::Canvas.new(grid, 0, 0, w, h), snap, state)
    grid
  end

  def draw(snap, state, w: 40, h: 6) = grid_of(snap, state, w: w, h: h).to_text(:none).lines.map(&:rstrip)

  def key(state, action, *args) = pane.key_action(action, state, *args)

  # The pane's body as drawn before it had keys (master-ai 3eb6e06b), as
  # the oracle for "no look change outside the mode".
  def old_body(c, s)
    name_w = [[s.knobs.map { |k| k.name.to_s.length }.max, 4].max, 8].min
    s.knobs.first(c.h).each_with_index do |k, y|
      spec = k.spec
      value = "#{ui::Panes.fmt(k.value)}#{spec.unit ? " #{spec.unit}" : ''}"
      x = c.line(y, [c.pad(k.name, name_w), :name], ' ')
      mw = [c.w - x - value.length - 1, 3].max
      x = c.meter(spec.position(k.value).to_f, width: mw, x: x, y: y, role: :key)
      c.text(x + 1, y, value, :text)
    end
  end

  around do |ex|
    @now = 100.0
    ui::Panes::Knobs.clock = -> { @now }
    ex.run
  ensure
    ui::Panes::Knobs.clock = nil
  end

  it 'draws the same cells and colors outside its mode as before it had keys, with no more allocations' do
    [[40, 6], [40, 3], [28, 6]].each do |w, h|
      ours = MB::Term::Cells.new(w, h)
      theirs = MB::Term::Cells.new(w, h)
      st = {}
      pane.draw_body(ui::Canvas.new(ours, 0, 0, w, h), snap, st)
      old_body(ui::Canvas.new(theirs, 0, 0, w, h), snap)
      expect(ours.to_text(:ansi256)).to eq(theirs.to_text(:ansi256)), "#{w}x#{h}"
    end
    # (after keys in the mode and leaving it: the same again)
    st = { mode: true }
    draw(snap, st)
    key(st, :pick, 2)
    st[:mode] = false
    expect(grid_of(snap, st).to_text(:ansi256)).to eq(grid_of(snap, {}).to_text(:ansi256))

    c = ui::Canvas.new(MB::Term::Cells.new(40, 6), 0, 0, 40, 6)
    st = {}
    count = ->(&b) { 3.times(&b); GC.disable; a = GC.stat(:total_allocated_objects); 20.times(&b); n = GC.stat(:total_allocated_objects) - a; GC.enable; n }
    ours = count.() { pane.draw_body(c, snap, st) }
    theirs = count.() { old_body(c, snap) }
    expect(ours).to be < theirs + 20 # (less than one object a draw more: the state's snapshot slot, once)
  end

  it 'picks a knob with a reversed cursor only in its mode, scrolling to it' do
    st = { mode: true }
    lines = draw(snap, st, h: 2)
    expect(lines[0]).to start_with('cut ')
    cells = grid_of(snap, st, h: 2)
    expect(cells.to_text(:ansi256)).to match(/\e\[7[;m]/) # (the cursor)
    expect(grid_of(snap, {}, h: 2).to_text(:ansi256)).not_to match(/\e\[7[;m]/)
    expect(key(st, :pick, 1)).to include('drive')
    expect(key(st, :pick, 1)).to include('bass/dub/space')
    lines = draw(snap, st, h: 2)
    expect(lines[0]).to start_with('drive ') # (scrolled: the picked one on the last row)
    expect(lines[1]).to start_with('bass/du')
    key(st, :pick, 9) # (clamped)
    expect(st[:pick]).to eq(3)
    expect(draw(snap, st, h: 2)[1]).to include('1800 Hz')
    key(st, :pick, -3)
    expect(draw(snap, st, h: 2)[0]).to start_with('cut ')
    expect(key({ snap: snap.with(knobs: [].freeze) }, :pick, 1)).to eq('no knobs')
  end

  it 'turns by position steps (Shift: fine), live while held with one line when the keys stop, and carries the value 0.6 s' do
    st = { mode: true }
    draw(snap, st)
    key(st, :pick, 1) # drive: 0.3 in 0..1
    expect(key(st, :turn, ui::KnobTurns::STEP)).to eq([pk::Preview[:drive, 0.32]])
    expect(pane.key_wait(st)).to be_within(1e-9).of(ui::TurnGesture::GAP)
    expect(draw(snap, st)[1]).to end_with('0.32') # (the gesture's target, before the snapshot has it)
    @now += ui::TurnGesture::GAP
    expect(pane.key_tick(st)).to eq(pk::Commit[:drive, 'drive 0.32'])
    pane.lines_ran(st)
    # (the snapshot still says 0.3: the next key steps on from 0.32)
    expect(draw(snap, st)[1]).to end_with('0.32')
    @now += 0.1
    expect(key(st, :turn, -ui::KnobTurns::FINE)).to eq([pk::Preview[:drive, 0.318]])
    @now += ui::TurnGesture::GAP
    pane.key_tick(st)
    pane.lines_ran(st)
    @now += ui::KnobTurns::PENDING + 0.01
    expect(draw(snap, st)[1]).to end_with('0.3') # (past PENDING: the snapshot's again)

    # A held key: repeats 33 ms apart after a 0.4 s delay, every one a step on, one commit
    previews = [key(st, :turn, ui::KnobTurns::STEP)]
    @now += 0.4
    10.times { previews << key(st, :turn, ui::KnobTurns::STEP); @now += 0.033 }
    expect(previews.map { |p| p[0].value }).to eq((1..11).map { |i| (0.3 + 0.02 * i).round(2) })
    @now += ui::TurnGesture::GAP
    expect(pane.key_tick(st)).to be_a(pk::Commit)
  end

  it "sets the knob's default with 0 and a typed value with Enter, each one turn line" do
    st = { mode: true }
    draw(snap, st)
    expect(key(st, :reset)).to eq([pk::Turn['turn :cut, 800', 'cut 800']])
    expect(draw(snap, st)[0]).to end_with('800 Hz') # (carried until the snapshot has it)
    ask = key(st, :ask)
    expect(ask).to eq([pk::Ask['turn :cut, ', 800, :typed, select: true]])
    expect(key(st, :typed, '3000.hz')).to eq(pk::Turn['turn :cut, 3000.hz', 'cut 3000.hz'])
    expect(key(st, :typed, '3000.hzz')).to match(/numbers have no \.hzz/)
    expect(key({ snap: snap.with(knobs: [].freeze) }, :turn, 0.02)).to include('no knobs to turn')
  end

  it 'turns a build knob one turn line a press, never a held sweep, as the inspector does' do
    st = { mode: true }
    s = snap.with(slow: snap.slow.with(build_knobs: [:drive].freeze))
    draw(s, st)
    key(st, :pick, 1)
    expect(key(st, :turn, ui::KnobTurns::STEP)).to eq(pk::Turn['turn :drive, 0.32', 'drive 0.32'])
    expect(key(st, :turn, ui::KnobTurns::STEP)).to eq(pk::Turn['turn :drive, 0.34', 'drive 0.34']) # (on from the carried value)
    expect(pane.key_wait(st)).to be_nil
  end

  it "shows the latest turn line on its last row only in its mode" do
    st = { mode: true, turn_line: 'turn :cut, 800' }
    expect(draw(snap, st).last).to eq('turn :cut, 800')
    st[:mode] = false
    expect(draw(snap, st).last).not_to include('turn :cut')
  end

  it 'declares the racks pane\'s knob keys (and Enter) in its mode keymap' do
    keys = ->(k) { k.mode_keymap.entries.map { |b| [b.chord, b.action, b.args] } }
    racks = keys.(ui::Panes::Racks)
    ours = keys.(ui::Panes::Knobs)
    expect(ours).to include(*racks)
    expect(ours.map { |c, _, _| c[0] }).to include(:enter, 'y')
    expect(ui::Panes::Knobs.keymap.help_groups.flatten.join(' ')).to include('Enter', 'pick and turn knobs')
    expect(ui::Panes::Knobs.jump).to be_nil
  end

  describe 'on a screen' do
    after do
      @tiles&.stop
      @term&.close
      @session&.close
      MB::Sound.rewind
    end

    it 'goes into the pane from NAV, turns a knob of a loaded demo with the arrows, and journals the turn' do
      ui::Panes::Knobs.clock = nil # (the real clock: the screen ends the gesture)
      # (its own transport: the demo sets the tempo)
      @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      expect { MB::Sound::Session.with_context(session: @session) { MB::Sound.demo(:night_bus) } }.to output(/demo :night_bus/).to_stdout
      4.times { @session.process_buffer }
      @tiles, @term = ui_tiles(:session, rows: 40, cols: 120, session: @session)
      stop = false
      pump = Thread.new { until stop; @session.process_buffer; sleep 0.02; end }
      @tiles.show(:knobs, at: :repl) unless @tiles.tiler.layout.panes.include?(:knobs) # (beside the REPL when the layout left it out)
      expect(@term.wait_for('cut ')).to eq(true), @term.text
      @tiles.enter(:knobs)
      expect(wait_until { @tiles.router.mode == :pane }).to eq(true)
      @term.write("\e") # (Esc: NAV, the knobs pane focused)
      expect(wait_until { @tiles.router.mode == :nav && @tiles.tiler.focus == :knobs }).to eq(true)
      @term.write("\r") # (NAV Enter: the pane's mode)
      expect(wait_until { @tiles.router.mode == :pane && @tiles.tiler.focus == :knobs }).to eq(true)
      st = @tiles.instance_variable_get(:@states)[:knobs]
      expect(wait_until { st[:snap] && !st[:snap].knobs.empty? }).to be_truthy
      name = st[:snap].knobs[0].name
      before = @session.knobs[name].value
      before_turns = @session.journal.changes.count { |e| e.kind == :turn }
      @term.write("\e[C")
      expect(wait_until { @session.knobs[name].value > before }).to eq(true) # (live, as the key goes)
      # (the gesture's one line: the pane's turn line, on its last row, not
      # in the REPL pane: KnobTurns, inspector-headers-1)
      expect(wait_until { st[:turn_line].to_s.start_with?("turn #{name.inspect}, ") }).to eq(true), st[:turn_line].inspect
      expect(@term.text).not_to include("turn #{name.inspect}, ")
      expect(wait_until { @session.journal.changes.count { |e| e.kind == :turn } == before_turns + 1 }).to eq(true)
      expect(@tiles.mode_problems).to eq([])
    ensure
      stop = true
      pump&.join
    end
  end
end
