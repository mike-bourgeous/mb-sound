require_relative '../../../../support/ui_helpers'

# The mb-term gem (gems/mb-term: the UI's generic layers) as mb-sound uses
# it: its native grids, Tiles as the Router's host, and the layouts built
# from mb-sound's panes.  The gem's own specs are in gems/mb-term/spec.
RSpec.describe('mb-term in mb-sound', :aggregate_failures) do
  include UIHelpers

  it 'keeps the old UI names as the gem\'s (until the follow-up removes them)' do
    expect(MB::Sound::UI::VT).to equal(MB::Term::VT)
    expect(MB::Sound::UI::Term).to equal(MB::Term::Terminal)
    expect(MB::Sound::UI::Input::Router).to equal(MB::Term::Input::Router)
    expect(MB::Sound::UI::Viewports::Tiler).to equal(MB::Term::Viewports::Tiler)
    expect(MB::Sound::UI::Themes).to equal(MB::Term::Themes)
    expect(MB::Sound::UI::DataFile::LoadError).to equal(MB::Term::DataFile::LoadError)
    expect(MB::Sound::UI::Screen).to equal(MB::Term::Screen)
    expect(MB::Sound::Plot::Text::Cells).to equal(MB::Term::Cells)
    expect(MB::Sound::Plot::Text::ANSI).to equal(MB::Term::ANSI)
  end

  it 'registers its native cells as the gem\'s native grid (the adapter)' do
    expect(MB::Term::Grid.native).to equal(MB::Sound::Plot::Text::NativeCells)
    expect(MB::Term::Grid.new(4, 2, native: true)).to be_a(MB::Sound::Plot::Text::NativeCells)
  end

  it 'draws a VT the same into Cells and NativeCells' do
    vt = MB::Term::VT.new(5, 10)
    vt.feed("\e[31mred\e[0m plain\r\n\e[44mblue\e[0m 中x")
    a = MB::Term::Cells.new(12, 5)
    b = MB::Sound::Plot::Text::NativeCells.new(12, 5)
    vt.draw(a, 1, 0, 11, 5)
    vt.invalidate
    vt.draw(b, 1, 0, 11, 5)
    %i[none ansi16 ansi256 truecolor].each { |m| expect(b.lines(m)).to eq(a.lines(m)) }
  end

  it 'finds every Router host method public on Tiles (an optional one that is private would be skipped silently)' do
    MB::Term::Input::Router::HOST_METHODS.each do |m|
      expect(MB::Sound::UI::Tiles.public_method_defined?(m)).to eq(true), "Tiles##{m} is not public"
    end
  end

  it 'copies the REPL pane\'s colored lines out of the tiles with their colors (UI::Switch)' do
    @tiles, @term = ui_tiles(:tiles)
    expect(@term.wait_for('t> ')).to eq(true)
    @tiles.host.vt.feed("\e[32mgreen\e[0m and plain\r\n") # (colored console output, as the pane holds it)
    lines = MB::Sound::UI::Switch.repl_lines(@tiles, color: true)
    expect(lines.join("\n")).to include("\e[0;32mgreen\e[0m and plain")
    expect(MB::Sound::UI::Switch.repl_lines(@tiles, color: false).join("\n")).to include("green and plain")
    expect(MB::Sound::UI::Switch.repl_lines(@tiles, color: false).join).not_to include("\e[")
  ensure
    @tiles&.stop
    @term&.close
  end

    it 'shows every built-in pane in the :wall layout at 200x60 (ux-1 item 13; the set\'s and sound design\'s panes have their own layouts)' do
      rects = MB::Sound::UI.tile_layouts[:wall].rects(200, 59)
      expect(rects.keys).to include(:repl, *(MB::Sound::UI.panes.keys - MB::Sound::UI::ON_DEMAND_PANES.keys - MB::Sound::UI::SESSION_PANES - MB::Sound::UI::SOUND_PANES))
      rects.each_value { |r| expect(r.w * r.h).to be > 0 }
      expect(rects[:repl].w).to be >= 90
    end
end
