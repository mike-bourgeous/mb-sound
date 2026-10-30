require_relative '../../../../support/ui_helpers'
require_relative '../../../../support/golden'

# Layout decisions by terminal size in one place (MB::Sound::UI::Density; ux-1 r3
# pattern E, items 3, 13, 24), with golden captures of the bands and the
# tiled screen at 80x24, 120x40, and 236x80.
RSpec.describe(MB::Sound::UI::Density, :aggregate_failures) do
  golden_sizes = [[24, 80], [40, 120], [80, 236]]

  # (the library picker's entries: a fixed fake library, not the shipped one)
  before { allow(MB::Sound::UI::Picker).to receive(:index).and_return(ui_fake_library) }

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

    %i[tiles studio session mixer sound].each do |layout|
      it "matches the golden capture of the #{layout} screen at #{cols}x#{rows}" do
        set = %i[session mixer].include?(layout) # (ux-r4: the set's panes with rack rack knobs)
        expect_golden("tiles_#{layout}_#{cols}x#{rows}", tiles_capture(layout, rows, cols, rack_knobs: set).to_text)
      end
    end

    # envelope-view-1: the sound screen's preview of an amp envelope with
    # a note in its decay (playhead) at peak 0.7 (the velocity trace)
    it "matches the golden capture of the sound screen's envelope preview at #{cols}x#{rows}" do
      MB::Sound::UI::Panes::Preview.clock = -> { 0.0 }
      snap = -> { s = ui_fake_snapshot; s.with(slow: s.slow.with(inspector: ui_fake_envelope_inspector)) }
      expect_golden("tiles_sound_envelope_#{cols}x#{rows}", tiles_capture(:sound, rows, cols, snap: snap).to_text)
    ensure
      MB::Sound::UI::Panes::Preview.clock = nil
    end
  end

  # sound-design-nav-1 (the maintainer: "ui :sound with density rules"):
  # the sound screen's built-in layout in fewer panes on smaller screens,
  # switching on a resize while it is as built, and the inspector's view by
  # the screen's level (the panel at 80x24, sections from 120x40)
  it 'shows ui :sound in fewer panes on smaller screens, as built, with the panel at 80x24' do
    small = tiles_capture(:sound, 24, 80)
    expect(small.tiler.layout.panes).to eq(%i[transport form inspector preview repl])
    expect(small.to_text).to include('SOUND', 'PREVIEW')
    expect(small.to_text).not_to include('LIBRARY', 'KEYS', 'TRACKS')
    expect(MB::Sound::UI.panes[:inspector].view(small.instance_variable_get(:@states)[:inspector])).to eq(:panel)
    mid = tiles_capture(:sound, 40, 120)
    expect(mid.tiler.layout.panes).to include(:tracks, :inspector, :preview, :code, :render, :audition)
    expect(mid.tiler.layout.panes).to include(:picker) # (ui-scaffold-1: the library picker under the tracks)
    expect(mid.tiler.layout.panes).not_to include(:sound_keys)
    expect(MB::Sound::UI.panes[:inspector].view(mid.instance_variable_get(:@states)[:inspector])).to eq(:sections)
    expect(tiles_capture(:sound, 80, 236).tiler.layout).to eq(MB::Sound::UI.tile_layouts[:sound])

    # A resize moves between the versions; a layout the user changed stays
    t = tiles_capture(:sound, 24, 80)
    t.instance_variable_set(:@fixed_size, [40, 120])
    t.instance_variable_set(:@resized, true)
    t.refresh(1.0)
    expect(t.tiler.layout).to eq(MB::Sound::UI.tile_layout_at(:sound, :normal))
    t.close(:audition)
    t.refresh(2.0)
    edited = t.tiler.layout
    t.instance_variable_set(:@fixed_size, [24, 80])
    t.instance_variable_set(:@resized, true)
    t.refresh(3.0)
    expect(t.tiler.layout).to eq(edited)
  end

  # ux-fix-1 (maintainer: help pages "as ui overlay when ui is up"): the
  # page pane under the console, scrolled with its keys, q closes it
  it 'shows a help page in a temporary page pane under the console, scrolls it, and q gives the layout back' do
    tiles = tiles_capture(:studio, 40, 120)
    before = tiles.tiler.layout
    text = (1..80).map { |i| "line #{i} of the page" }.join("\n")
    tiles.page(text, title: 'help :render')
    expect(tiles.tiler.layout.panes).to include(:page)
    expect(tiles.tiler.rects[:repl].h).to be >= MB::Sound::UI::Tiles::REPL_MIN_ROWS
    tiles.refresh(0.0)
    expect(tiles.to_text).to include('line 1 of the page', 'HELP :RENDER', 'lines 1-')
    tiles.send(:pane_action, :page, :scroll, :bottom)
    tiles.refresh(1.0)
    expect(tiles.to_text).to include('line 80 of the page')
    tiles.send(:pane_action, :page, :close)
    expect(tiles.tiler.layout.panes).not_to include(:page)
    expect(tiles.tiler.layout.root).to eq(before.root)
  end

  # ux-fix-1 item 8: `ui :studio` at 80x24 left the console 12 columns
  it 'keeps the console at least REPL_MIN_COLS wide in every built-in tiled layout at 80x24' do
    min = MB::Sound::UI::Tiles::REPL_MIN_COLS
    MB::Sound::UI.tile_layouts.each_key do |layout|
      r = tiles_capture(layout, 24, 80).tiler.rects[:repl]
      expect(r.w).to be >= min, "#{layout}: #{r.w} columns"
    end
  end

  after do
    @capture&.stop
    @capture_term&.close
  end

  # A tiled screen at +rows+ x +cols+ drawing ui_fake_snapshot once, without
  # a console (so its text is deterministic; the REPL pane stays empty).
  def tiles_capture(layout, rows, cols, rack_knobs: false, snap: nil)
    @capture&.stop
    @capture_term&.close
    @capture_term = UIHelpers::FakeTerminal.new(rows, cols)
    @capture = MB::Sound::UI::Tiles.new(layout: MB::Sound::UI.tiles_layout_named(layout), input: @capture_term.slave, output: @capture_term.slave, repl: :none,
                             probe: false, size: [rows, cols], clock: -> { 0.0 }, source: snap || -> { ui_fake_snapshot(rack_knobs: rack_knobs) },
                             keyboard: MB::Sound::UI::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @capture.start(thread: false)
    @capture.refresh(0.0)
    @capture
  end
end
