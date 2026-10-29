require_relative '../../../../support/ui_helpers'

# The dashboard band (MB::Sound::UI::Band): deterministic text from fixed
# snapshots and clocks, native grid vs the Ruby mirror, the frames' terminal
# bytes (scroll region, save/restore cursor, synchronized output), diffed
# frames replayed through MB::Term::Screen, per-pane rates, and failing panes.
RSpec.describe(MB::Sound::UI::Band, :aggregate_failures) do
  # The :band layout at 120 columns with ui_fake_snapshot, left of the
  # scope's trace (the scope draws into the grid too since ui-fix-3).
  BAND_TEXT = <<~TEXT
    ▶ 17:3   128 bpm 4/4  load  31% ▃  xruns 0                  drop 1 ████▌    5/8  → break 21:1
    TRACKS                      QUEUED                   MASTER                      SCOPE
    ● drums  beat_a             17:3   knob :cut         L ████████████████▍    -8.1
    ● bass   bass_a             18:1   mute :pad         R ████████████████▍    -8.4
    ● lead   rec →21:1                                   S -14.2 LUFS  TP -0.6
    ● pad    stopping chords                             RMS -18.0 -18.2
  TEXT

  # The band's rule toward the console (ux-1 r3 item 3; 25 rows and up).
  BAND_RULE = '─' * 120

  def rstripped(text) = text.lines.map(&:rstrip).join("\n").sub(/\n+\z/, '')

  it 'draws the default band from a snapshot' do
    band, = ui_fake_band(:band)
    band.start(thread: false)
    band.refresh(0.0)
    expect(band.height).to eq(8)
    text = band.to_text.lines.map(&:chomp)
    scope_x = BAND_TEXT.lines[1].index('SCOPE')
    expect(rstripped(text.map { |l| l[0, scope_x] }.join("\n"))).to eq(rstripped((BAND_TEXT.lines.map { |l| l.chomp[0, scope_x] } + ["", BAND_RULE[0, scope_x]]).join("\n")))
    expect(text[1][scope_x..]).to start_with('SCOPE')
    expect(text[2..5].map { |l| l[scope_x..] }.join).to match(/[⠁-⣿]/) # (its Braille trace, in the grid)
    expect(text.last).to eq(BAND_RULE)
  end

  it 'draws the deck with knobs and CPU per part' do
    band, = ui_fake_band(:deck)
    band.start(thread: false)
    band.refresh(0.0)
    lines = band.to_text.lines.map(&:rstrip)
    expect(lines.pop).to eq(BAND_RULE) # (the rule toward the console)
    expect(lines[1]).to match(/\ATRACKS +QUEUED +KNOBS\z/)
    expect(lines[2]).to match(/cut +█+▉? +2400 Hz\z/)
    expect(lines[3]).to match(/drive +█+ +0\.3\z/)
    cpu = lines.index { |l| l.include?('MASTER') }
    expect(lines[cpu + 1]).to include('all  31% max 45%')
    # Parts by load, the master and buses included
    expect(lines[(cpu + 2)..].map { |l| l[/(bass|verb|drums|master|pad)\s+█/, 1] }.compact).to eq(%w[bass verb drums master pad].first(lines.length - cpu - 2))
  end

  it 'gives the same text and bytes with the native grid and the Ruby mirror' do
    %i[band deck mini].each do |layout|
      %i[ansi256 truecolor none].each do |mode|
        native, nio = ui_fake_band(layout, native: true, color: mode)
        ruby, rio = ui_fake_band(layout, native: false, color: mode)
        [native, ruby].each { |b| b.start(thread: false) }
        3.times do |i|
          snap = ui_fake_snapshot(t: i * 0.05, seq: i + 1, scope_phase: i * 0.1, peak: -8.1 - i)
          [native, ruby].each { |b| b.instance_variable_set(:@source, -> { snap }) }
          native.refresh(i * 0.05)
          ruby.refresh(i * 0.05)
        end
        expect(native.to_text(mode)).to eq(ruby.to_text(mode)), "#{layout} #{mode}"
        expect(nio.string).to eq(rio.string), "#{layout} #{mode}"
      end
    end
  end

  it 'wraps each refresh in synchronized output and a saved cursor, reasserting the scroll region' do
    band, io = ui_fake_band(:band, size: [30, 120])
    band.start(thread: false)
    setup = io.string.dup
    expect(setup).to eq("\e[30;1H#{"\n" * 8}\e[9;30r\e[22;1H")

    out = band.refresh(0.0)
    expect(out).to start_with("\e[?2026h\e7\e[9;30r\e[0m\e[1;1H")
    expect(out).to end_with("\e8\e[?2026l")
    expect(io.string).to eq(setup + out)

    # Nothing changed and no reassertion due: nothing is written
    expect(band.refresh(0.5)).to be_nil

    # The scroll region is reissued (with a full redraw) every REASSERT seconds
    again = band.refresh(described_class::REASSERT + 0.1)
    expect(again).to start_with("\e[?2026h\e7\e[9;30r")
    expect(again.bytesize).to be > 1000

    band.stop
    expect(io.string).to end_with("\e7\e[r#{(1..8).map { |r| "\e[#{r};1H\e[2K" }.join}\e8")
  end

  it 'leaves the top rows to Pry with the band at the bottom' do
    band, io = ui_fake_band(:band, size: [30, 120], at: :bottom)
    band.start(thread: false)
    expect(band.region).to eq([1, 22])
    expect(band.band_top).to eq(23)
    out = band.refresh(0.0)
    expect(out).to start_with("\e[?2026h\e7\e[1;22r\e[0m\e[23;1H")
    screen = MB::Term::Screen.new(30, 120)
    screen << io.string
    # The rule first, between the console and the band (ux-1 r3 item 3)
    expect(rstripped(screen.lines.last(8).map { |l| l[0, 80] }.join("\n"))).to eq(rstripped(([BAND_RULE] + BAND_TEXT.lines).map { |l| l.chomp[0, 80] }.join("\n")))
  end

  it 'rebuilds the full frame from diffed frames (replayed through MB::Term::Screen)' do
    i = 0
    band, io = ui_fake_band(:deck) { ui_fake_snapshot(t: i * 0.04, seq: i + 1, scope_phase: i * 0.13, peak: -6.0 - (i % 7)) }
    band.start(thread: false)
    screen = MB::Term::Screen.new(30, 120)
    40.times do |k|
      i = k
      band.refresh(k * 0.04)
    end
    screen << io.string

    # The same band's full redraw of its last frame (same snapshot and
    # time, so stateful panes like the peak hold draw the same) on a blank
    # screen
    band.invalidate
    full = band.refresh(39 * 0.04)
    expected = MB::Term::Screen.new(30, 120)
    expected << full
    expect(screen.lines(:ansi256).first(band.height)).to eq(expected.lines(:ansi256).first(band.height))
    expect(screen.lines.first(band.height).join).to include('-6.0') # the hold from the loudest snapshot
    # The rows below the band are untouched (the cursor came back each time)
    expect(screen.lines.drop(band.height).join.strip).to eq('')
    expect([screen.row, screen.col]).to eq([band.rows - band.height - 1, 0])
  end

  it 'redraws each pane at its own rate, passing the GVL between panes' do
    band, = ui_fake_band(:deck)
    band.start(thread: false)
    drawn = Hash.new(0)
    band.placed.each do |p|
      pane = p.pane
      orig = pane.method(:draw)
      p.pane = pane.clone
      p.pane.define_singleton_method(:draw) { |*a, **k| drawn[pane.name] += 1; orig.call(*a, **k) }
    end

    allow(Thread).to receive(:pass).and_call_original
    band.refresh(0.0) # everything (first frame)
    100.times { |k| band.refresh((k + 1) / 100r) } # 10 ms ticks for a second, before the next reassertion
    # A pane is due 1 ms early, so at 10 ms ticks the live panes (transport,
    # knobs, meters, scope: at the 60/s target, UI::PaneRates) draw every 20
    # ms, 8/s every 130, 4/s every 250
    expect(drawn).to eq(transport: 51, form: 8, tracks: 8, queue: 5, knobs: 51, meters: 51, cpu: 5, scope: 51)
    expect(Thread).to have_received(:pass).exactly(drawn.values.sum).times
    expect(band.stats[:yields]).to eq(drawn.values.sum)
  end

  it 'shows a failing pane as an error and keeps drawing the others' do
    MB::Sound::UI.define_pane(:boom, height: 2) { |_c, _s| raise 'kaput' }
    MB::Sound::UI.define_layout(:boom_test) { cols { pane :transport; pane :boom } }
    band, = ui_fake_band(:boom_test)
    band.start(thread: false)
    expect { band.refresh(0.0) }.to output(/UI pane boom: RuntimeError: kaput/).to_stderr
    expect(band.to_text.lines[0]).to include('17:3').and include('boom failed: kaput')
    expect(band.failures).to eq(boom: 'boom: RuntimeError: kaput')
    expect { band.refresh(1.0) }.not_to output.to_stderr # warned once
  ensure
    MB::Sound::UI.panes.delete(:boom)
    MB::Sound::UI.layouts.delete(:boom_test)
  end

  it 'follows terminal size changes' do
    band, io = ui_fake_band(:band, size: [30, 120])
    band.start(thread: false)
    band.refresh(0.0)
    band.instance_variable_set(:@fixed_size, [40, 100])
    band.resized!
    out = band.refresh(0.1)
    expect([band.rows, band.cols]).to eq([40, 100])
    expect(out).to start_with("\e[?2026h\e7\e[9;40r")
    screen = MB::Term::Screen.new(40, 100)
    screen << out
    expect(screen.lines[0]).to start_with('▶ 17:3')
    expect(io.string.length).to be > out.length
  end

  it 'skips painting when the terminal is too short for the band and a prompt' do
    band, = ui_fake_band(:deck, size: [15, 120])
    band.start(thread: false)
    expect(band.refresh(0.0)).to be_nil
  end

  it 'draws without a session' do
    band, = ui_fake_band(:mini) { nil }
    band.start(thread: false)
    band.refresh(0.0)
    expect(band.to_text).to include('no session yet')
  end

  it 'grows and shrinks at the bottom without asking the terminal for its cursor, the console\'s lines scrolled up (ux-1 r3 item 2)' do
    band, io = ui_fake_band(:band, size: [30, 120], at: :bottom)
    band.start(thread: false)
    band.refresh(0.0)
    screen = MB::Term::Screen.new(30, 120)
    # The console's lines just above the band, the cursor on the last
    screen << io.string << "\e[1;1H" << (1..22).map { |i| "line #{i}" }.join("\r\n")
    io.truncate(0)
    io.rewind
    close = nil
    Thread.new { close = band.plot_pane(:messages, height: 4) }.join # (from another thread, as the painter does)
    expect(io.string).not_to include("\e[6n")
    screen << io.string
    lines = screen.lines.map(&:rstrip)
    expect(band.height).to eq(12)
    expect(lines[17]).to eq('line 22') # (scrolled up by the 4 rows the band grew)
    expect(lines[14]).to eq('line 19')
    expect([screen.row, screen.col]).to eq([17, 7]) # (back after line 22)
    expect(lines[18..].join).not_to include('line')

    # Shrinking back leaves the console's lines and the cursor where they are
    io.truncate(0)
    io.rewind
    Thread.new { close.call }.join
    expect(io.string).not_to include("\e[6n")
    screen << io.string
    lines = screen.lines.map(&:rstrip)
    expect(band.height).to eq(8)
    expect(lines[17]).to eq('line 22')
    expect([screen.row, screen.col]).to eq([17, 7])
    expect(lines[18..21].join.strip).to eq('')
  end
end
