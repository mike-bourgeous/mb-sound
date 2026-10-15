require_relative '../../../../support/ui_helpers'

# The dashboard band (MB::Sound::UI::Band): deterministic text from fixed
# snapshots and clocks, native grid vs the Ruby mirror, the frames' terminal
# bytes (scroll region, save/restore cursor, synchronized output), diffed
# frames replayed through UI::Screen, per-pane rates, and failing panes.
RSpec.describe(MB::Sound::UI::Band, :aggregate_failures) do
  # The :band layout at 120 columns with ui_fake_snapshot (scope pane
  # bytes not included: Band#to_text is the cell grid).
  BAND_TEXT = <<~TEXT
    ▶ 17:3   128 bpm 4/4  load  31% ▃  xruns 0                  drop 1 ████▌    5/8  → break 21:1
    TRACKS                      QUEUED                   MASTER
    ● drums  beat_a             17:3   knob :cut         L ████████████████▍    -8.1
    ● bass   bass_a             18:1   mute :pad         R ████████████████▍    -8.4
    ● lead   rec →21:1                                   S -14.2 LUFS  TP -0.6
    ● pad    stopping chords                             RMS -18.0 -18.2
  TEXT

  def rstripped(text) = text.lines.map(&:rstrip).join("\n").sub(/\n+\z/, '')

  it 'draws the default band from a snapshot' do
    band, = ui_fake_band(:band)
    band.start(thread: false)
    band.refresh(0.0)
    expect(band.height).to eq(7)
    expect(rstripped(band.to_text)).to eq(rstripped(BAND_TEXT))
  end

  it 'draws the deck with knobs and CPU per part' do
    band, = ui_fake_band(:deck)
    band.start(thread: false)
    band.refresh(0.0)
    lines = band.to_text.lines.map(&:rstrip)
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
    expect(setup).to eq("\e[30;1H#{"\n" * 7}\e[8;30r\e[23;1H")

    out = band.refresh(0.0)
    expect(out).to start_with("\e[?2026h\e7\e[8;30r\e[0m\e[1;1H")
    expect(out).to end_with("\e8\e[?2026l")
    expect(io.string).to eq(setup + out)

    # Nothing changed and no reassertion due: nothing is written
    expect(band.refresh(0.5)).to be_nil

    # The scroll region is reissued (with a full redraw) every REASSERT seconds
    again = band.refresh(described_class::REASSERT + 0.1)
    expect(again).to start_with("\e[?2026h\e7\e[8;30r")
    expect(again.bytesize).to be > 1000

    band.stop
    expect(io.string).to end_with("\e7\e[r#{(1..7).map { |r| "\e[#{r};1H\e[2K" }.join}\e8")
  end

  it 'leaves the top rows to Pry with the band at the bottom' do
    band, io = ui_fake_band(:band, size: [30, 120], at: :bottom)
    band.start(thread: false)
    expect(band.region).to eq([1, 23])
    expect(band.band_top).to eq(24)
    out = band.refresh(0.0)
    expect(out).to start_with("\e[?2026h\e7\e[1;23r\e[0m\e[24;1H")
    screen = MB::Sound::UI::Screen.new(30, 120)
    screen << io.string
    expect(rstripped(screen.lines.last(7).map { |l| l[0, 80] }.join("\n"))).to eq(rstripped(BAND_TEXT.lines.map { |l| l.chomp[0, 80] }.join("\n")))
  end

  it 'rebuilds the full frame from diffed frames (replayed through UI::Screen)' do
    i = 0
    band, io = ui_fake_band(:deck) { ui_fake_snapshot(t: i * 0.04, seq: i + 1, scope_phase: i * 0.13, peak: -6.0 - (i % 7)) }
    band.start(thread: false)
    screen = MB::Sound::UI::Screen.new(30, 120)
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
    expected = MB::Sound::UI::Screen.new(30, 120)
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
      orig = pane.bytes? ? pane.method(:frame_bytes) : pane.method(:draw)
      p.pane = pane.clone
      if pane.bytes?
        p.pane.define_singleton_method(:frame_bytes) { |*a, **k| drawn[pane.name] += 1; orig.call(*a, **k) }
      else
        p.pane.define_singleton_method(:draw) { |*a| drawn[pane.name] += 1; orig.call(*a) }
      end
    end

    allow(Thread).to receive(:pass).and_call_original
    band.refresh(0.0) # everything (first frame)
    100.times { |k| band.refresh((k + 1) / 100r) } # 10 ms ticks for a second, before the next reassertion
    # A pane is due 1 ms early, so at 10 ms ticks 30/s panes draw every 40
    # ms, 15/s every 70, 8/s every 130, 4/s every 250
    expect(drawn).to eq(transport: 26, form: 8, tracks: 8, queue: 5, knobs: 15, meters: 26, cpu: 5, scope: 26)
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
    expect(out).to start_with("\e[?2026h\e7\e[8;40r")
    screen = MB::Sound::UI::Screen.new(40, 100)
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
end
