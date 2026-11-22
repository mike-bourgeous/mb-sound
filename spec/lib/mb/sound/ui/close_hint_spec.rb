require_relative '../../../../support/ui_helpers'

# Closing a pane flashes how to get it back (console-offers-1, 2026-11-21),
# and what the flash says works: ui.undo puts the pane back where it was.
RSpec.describe(MB::Sound::UI::Tiles, :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
  end

  def start(layout = :tiles, **opts)
    @tiles, @term = ui_tiles(layout, **opts)
    expect(@term.wait_for('t> ')).to eq(true), @term.text
  end

  def flash = @tiles.instance_variable_get(:@flash)&.first
  def panes = @tiles.tiler.layout.panes

  it 'flashes the closed pane and ui.undo after NAV x, and undo brings it back without a hint of its own' do
    start
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type((@tiles.tiler.numbered.index(:scope) + 1).to_s)
    expect(wait_until { @tiles.tiler.focus == :scope }).to eq(true)
    @term.type('x')
    expect(wait_until { !panes.include?(:scope) }).to eq(true)
    expect(flash).to eq('closed scope: ui.undo brings it back, or ui.show :scope in the focused slot')
    @tiles.refresh
    expect(@term.wait_for('closed scope: ui.undo brings it back')).to eq(true) # (on the status line)

    @tiles.instance_variable_set(:@flash, nil)
    @tiles.undo
    expect(panes).to include(:scope)
    expect(flash).to be_nil
  end

  it 'names a closed page by its alias too; undo restores its text, and the next page opens after a close' do
    start
    @tiles.page("first page text\nline 2", title: 'T')
    expect(panes).to include(:page)
    @tiles.close(:pager)
    expect(panes).not_to include(:page)
    expect(flash).to eq('closed page (also :pager): ui.undo brings it back, or ui.show :page in the focused slot')

    @tiles.undo
    expect(panes).to include(:page)
    @tiles.refresh
    expect(@tiles.to_text).to include('first page text')

    # (a page closed as a pane left its temporary closer behind, so the next
    # help page never opened)
    @tiles.close(:page)
    @tiles.page('second page text', title: 'U')
    expect(panes).to include(:page)
    @tiles.refresh
    expect(@tiles.to_text).to include('second page text')
  end

  it "doesn't flash for a page closed its own way (q: not an undo step) or for an empty slot" do
    start
    @tiles.page('a page', title: 'T')
    @tiles.instance_variable_set(:@flash, nil)
    @tiles.page(false)
    expect(panes).not_to include(:page)
    expect(flash).to be_nil

    @tiles.split(:v)
    empty = (panes - %i[transport form repl tracks queue meters scope]).first
    expect(empty.to_s).to match(/\Aempty\d+\z/)
    @tiles.close(empty)
    expect(flash).to be_nil
  end

  it 'lists the panes a show over a pane or a layout switch drops, and undo brings them back' do
    start
    @tiles.show(:knobs, at: :scope)
    expect(flash).to eq('closed scope: ui.undo brings it back, or ui.show :scope in the focused slot')
    @tiles.undo
    expect(panes).to include(:scope)
    expect(panes).not_to include(:knobs)

    before = panes
    @tiles.layout(:keys)
    gone = before - panes
    expect(gone).not_to be_empty
    expect(flash).to start_with("closed #{gone.join(', ')}: ui.undo brings #{gone.length == 1 ? 'it' : 'them'} back, or ui.show #{gone.first.inspect}")
    @tiles.undo
    expect(panes).to eq(before)
  end

  it 'opens the plot pane again after it was closed as a pane' do
    start(:tiles, rows: 40, cols: 160)
    chart = MB::Sound.chart { line Numo::SFloat[0, 1, 0, -1, 0] }
    @tiles.plot(chart)
    expect(panes).to include(:plot)
    @tiles.close(:plot)
    expect(flash).to start_with('closed plot: ui.undo')
    @tiles.plot(chart)
    expect(panes).to include(:plot)
  end
end
