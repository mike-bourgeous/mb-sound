require_relative '../../../../support/ui_helpers'

# ui.size, ui.list, and ui.panes (ux-1 r3 items 14, 27, 40): the same
# answers from a band, the tiles, and no screen at all.
RSpec.describe('UI listings', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  it 'lists every pane kind once, with what it shows, where it is used, and how to open it' do
    cat = ui.pane_catalog
    expect(cat.names).to match_array(ui.panes.keys)
    cat.entries.each do |e|
      expect(e.description.to_s).not_to be_empty, "#{e.name} has no description"
      expect(e.layouts.empty? ? ui::ON_DEMAND_PANES : e.layouts).not_to be_empty, "#{e.name}: in no layout and not on demand"
    end
    expect(cat[:scope].layouts).to include(:band, :tiles)
    expect(cat[:message].open).to eq('ui.message n')
    expect(cat.to_s).to include('pane', 'scope', 'Braille')
    expect(cat).to be_frozen
  end

  it 'lists a custom pane as :custom' do
    ui.define_pane(:listing_test, height: 2, description: 'a test') { |c, _s| c.puts 'x' }
    e = ui.pane_catalog[:listing_test]
    expect(e.kind).to eq(:custom)
    expect(e.description).to eq('a test')
  ensure
    ui.panes.delete(:listing_test)
  end

  it 'answers size and list from a band' do
    band, = ui_fake_band(:deck, size: [40, 120])
    band.start(thread: false)
    band.refresh(0.0)
    expect(band.size.to_s).to eq('40x120')
    expect(band.size).to have_attributes(rows: 40, cols: 120)
    l = band.list
    expect(l.mode).to eq(:band)
    expect(l.layout).to eq(:deck)
    expect(l.panes.map(&:name)).to eq(%i[transport form tracks queue knobs meters cpu scope])
    expect(l.panes.find { |p| p.name == :scope }.title_at).to eq(:inside)
    expect(l.to_s).to include('ui band :deck on 40x120 (normal, rule)', 'scope')
    expect(band.panes).to be_a(ui::PaneCatalog)
  end

  it 'answers size and list from the tiles, numbers, focus, and zoom included' do
    term = UIHelpers::FakeTerminal.new(40, 120)
    tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:tiles), input: term.slave, output: term.slave, repl: :none, probe: false,
                          size: [40, 120], clock: -> { 0.0 }, source: -> { ui_fake_snapshot },
                          keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    tiles.start(thread: false)
    tiles.refresh(0.0)
    tiles.zoom(:scope)
    l = tiles.list
    expect(l.mode).to eq(:tiles)
    expect(tiles.size.to_s).to eq('40x120')
    s = l.panes.find { |p| p.name == :scope }
    expect(s.rect.to_s).to eq('120x39+0+0') # (the tree now, before a frame drew it)
    expect(s).to have_attributes(zoomed: true, focused: true, kind: :scope, look: :scope)
    tiles.zoom(:scope)
    tiles.refresh(0.0)
    l = tiles.list
    expect(l.panes.map(&:number).compact).to eq((1..l.panes.length).to_a)
    expect(l.panes.find { |p| p.name == :repl }.kind).to eq(:repl)
    expect(l.density.header_rule).to eq(true)
    expect(l.to_s).to include('ui tiles :tiles on 40x120')
  ensure
    tiles&.stop
    term&.close
  end

  it 'answers with no screen up' do
    allow(ui).to receive(:screen).and_return(nil)
    l = ui.list
    expect(l.mode).to eq(:off).or eq(:hidden)
    expect(l.panes).to eq([])
    expect(ui.size).to be_a(ui::Size)
    expect(l.to_s).to start_with('ui off')
  end
end
