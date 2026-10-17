require_relative '../../../../support/ui_helpers'
require_relative '../../../../support/golden'

# Layout decisions by terminal size in one place (MB::Sound::UI::Density; ux-1 r3
# pattern E, items 3, 13, 24), with golden captures of the bands and the
# tiled screen at 80x24, 120x40, and 236x80.
RSpec.describe(MB::Sound::UI::Density, :aggregate_failures) do
  golden_sizes = [[24, 80], [40, 120], [80, 236]]

  it 'decides rules, boxes, and levels by size' do
    expect(described_class.decide(:band, 24, 80)).to have_attributes(level: :compact, rule: false, boxes: false, max_band_rows: nil)
    expect(described_class.decide(:band, 25, 80)).to have_attributes(level: :normal, rule: true, boxes: false)
    expect(described_class.decide(:band, 80, 236)).to have_attributes(level: :big, rule: true, boxes: true, max_band_rows: 26)
    expect(described_class.decide(:band, 80, 120)).to have_attributes(level: :normal) # tall but narrow
    expect(described_class.decide(:tiles, 24, 80).header_rule).to eq(false)
    expect(described_class.decide(:tiles, 40, 120).header_rule).to eq(true)
    expect(described_class.decide(:tiles, 40, 120).rule).to eq(false) # (the tiles have no band rule)
    expect(described_class.table.length).to eq(6)
    expect { described_class.decide(:wall, 1, 1) }.to raise_error(ArgumentError, /:band and :tiles/)
  end

  it 'gives every band layout a rule toward the console from RULE_MIN_ROWS rows, :mini included (item 3)' do
    %i[mini band deck].each do |layout|
      [[24, false], [25, true]].each do |rows, rule|
        %i[top bottom].each do |at|
          band, = ui_fake_band(layout, size: [rows, 120], at: at)
          band.start(thread: false)
          band.refresh(0.0)
          lines = band.to_text.lines.map(&:rstrip)
          edge = at == :top ? lines.last : lines.first
          expect(edge.match?(/\A─{120}\z/)).to eq(rule), "#{layout} #{rows} rows #{at}: #{edge.inspect}"
        end
      end
    end
  end

  it 'scales the deck up on a big terminal: boxes with titles set in, a third of the rows, more panes (item 13)' do
    band, = ui_fake_band(:deck, size: [80, 236], at: :bottom)
    band.start(thread: false)
    band.refresh(0.0)
    lines = band.to_text.lines.map(&:rstrip)
    expect(band.height).to eq(26)
    expect(lines.first).to start_with('┌─').and end_with('┐')
    expect(lines.last).to start_with('└─').and end_with('┘')
    expect(lines.join).to include('─ TRACKS ─', '─ KNOBS ─', '─ MESSAGES ─', '─ SPECTRUM ─', '─ SCOPE ─')
    expect(band.shown_layout.pane_names).to include(:spectrum, :messages)
    small, = ui_fake_band(:deck, size: [40, 120], at: :bottom)
    expect(small.shown_layout.pane_names).not_to include(:spectrum, :messages)
    expect(small.height).to eq(14) # 13 + the rule
  end

  it 'rules the tiles\' header off from the panes below on 25 rows and up (item 24)' do
    [[24, 80, false], [40, 120, true]].each do |rows, cols, rule|
      tiles = tiles_capture(:tiles, rows, cols)
      r = tiles.tiler.rects[:repl]
      expect(r.y).to eq(rule ? 2 : 1)
      expect(tiles.to_text.lines[1].start_with?('─')).to eq(rule)
    end
  end

  golden_sizes.each do |rows, cols|
    %i[mini band deck].each do |layout|
      it "matches the golden capture of the #{layout} band at #{cols}x#{rows}" do
        band, = ui_fake_band(layout, size: [rows, cols], at: :bottom)
        band.start(thread: false)
        band.refresh(0.0)
        expect_golden("band_#{layout}_#{cols}x#{rows}", band.to_text)
      end
    end

    %i[tiles studio].each do |layout|
      it "matches the golden capture of the #{layout} screen at #{cols}x#{rows}" do
        expect_golden("tiles_#{layout}_#{cols}x#{rows}", tiles_capture(layout, rows, cols).to_text)
      end
    end
  end

  after do
    @capture&.stop
    @capture_term&.close
  end

  # A tiled screen at +rows+ x +cols+ drawing ui_fake_snapshot once, without
  # a console (so its text is deterministic; the REPL pane stays empty).
  def tiles_capture(layout, rows, cols)
    @capture&.stop
    @capture_term&.close
    @capture_term = UIHelpers::FakeTerminal.new(rows, cols)
    @capture = MB::Sound::UI::Tiles.new(layout: MB::Sound::UI.tiles_layout_named(layout), input: @capture_term.slave, output: @capture_term.slave, repl: :none,
                             probe: false, size: [rows, cols], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                             keyboard: MB::Sound::UI::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @capture.start(thread: false)
    @capture.refresh(0.0)
    @capture
  end
end
