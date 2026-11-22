require_relative '../../../../support/ui_helpers'

# Swapping the focused pane with its neighbor by direction (the
# maintainer, 2026-11-21: "Is there a UI nav key to swap a panel with the
# panel to its left/right/etc?", then "Add the pane swap action"): NAV
# Alt-arrows and `ui.swap :left`, the same neighbor as the arrows' focus,
# sizes kept with the slots, the focus following the moved pane, one undo
# step each, a flash naming what moved.
RSpec.describe(MB::Sound::UI::Tiles, :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
  end

  def start(layout = :wall, **opts)
    @tiles, @term = ui_tiles(layout, rows: 50, cols: 160, **opts)
    expect(@term.wait_for('t> ')).to eq(true), @term.text
    @tiles.refresh
  end

  def flash = @tiles.instance_variable_get(:@flash)&.first
  def rects = @tiles.tiler.rects
  def nav = (@term.write("\x1d"); expect(@term.wait_for(' NAV ')).to eq(true))

  ALT = { left: "\e[1;3D", right: "\e[1;3C", up: "\e[1;3A", down: "\e[1;3B" }.freeze

  it 'walks the tracks pane right with NAV Alt-Right, and u twice puts it back, every pane drawing its own content' do
    start
    slots = rects
    nav
    @term.type((@tiles.tiler.numbered.index(:tracks) + 1).to_s)
    expect(wait_until { @tiles.tiler.focus == :tracks }).to eq(true)
    first = @tiles.tiler.neighbor(:right)
    expect(first).not_to be_nil

    # (the wall sizes some panes by their content, so a slot's size can
    # change with what it holds; the order is what a swap moves)
    @term.write(ALT[:right])
    expect(wait_until { rects[:tracks].x > rects[first].x }).to eq(true), rects.inspect
    expect(rects[first].x).to eq(slots[:tracks].x)
    expect(@tiles.tiler.focus).to eq(:tracks)
    expect(flash).to eq("tracks <-> #{first}")

    second = @tiles.tiler.neighbor(:right)
    if second
      @term.write(ALT[:right])
      expect(wait_until { rects[:tracks].x > rects[second].x || rects[:tracks].y > rects[second].y }).to eq(true), rects.inspect
      expect(flash).to eq("tracks <-> #{second}")
      @term.type('u')
    end
    @term.type('u')
    expect(wait_until { rects == slots }).to eq(true), rects.inspect

    # the panes draw their own content in their slots after the swaps
    @tiles.refresh
    text = @tiles.to_text
    expect(text).to include('tracks').or include('TRACKS')
  end

  it 'takes ui.swap :left / :right / :up / :down for the focused pane (the REPL, typed at the console) beside the by-name forms' do
    start
    slots = rects
    me = @tiles.tiler.focus
    expect(me).to eq(:repl)
    dir = %i[right left down up].find { |d| @tiles.tiler.neighbor(d) }
    n = @tiles.tiler.neighbor(dir)
    @tiles.swap(dir)
    expect(rects[n].x == slots[me].x && rects[n].y == slots[me].y).to eq(true), rects.inspect
    expect(@tiles.tiler.focus).to eq(me)
    expect(flash).to eq("#{me} <-> #{n}")
    @tiles.undo
    expect(rects).to eq(slots)

    # a direction with nothing that way changes nothing
    if (none = %i[left up right down].find { |d| @tiles.tiler.neighbor(d).nil? })
      @tiles.swap(none)
      expect(rects).to eq(slots)
      expect(flash).to match(/\Ano pane (to the #{none} of|above|below) #{me}\z/)
    end

    # no pane is named like a direction, so the two forms can't collide
    expect(MB::Sound::UI.pane_catalog.names & %i[left right up down]).to eq([])
    expect(MB::Sound::UI::PANE_ALIASES.keys & %i[left right up down]).to eq([])
    @tiles.swap(:tracks, n)
    expect(rects[n].x == slots[:tracks].x && rects[n].y == slots[:tracks].y).to eq(true), rects.inspect
  end
end
