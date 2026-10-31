require_relative '../../../../support/ui_helpers'

# The mb-term gem (gems/mb-term: the UI's generic layers) as mb-sound uses
# it: its native grids, Tiles as the Router's host, and the layouts built
# from mb-sound's panes.  The gem's own specs are in gems/mb-term/spec.
RSpec.describe('mb-term in mb-sound', :aggregate_failures) do
  include UIHelpers

  # (omnibus16 removed the aliases term-extract-1 kept; no legacy names)
  it 'has no aliases of the gem\'s names left on the mb-sound side' do
    %i[VT Term Screen Input Viewports Themes DataFile].each do |name|
      expect(MB::Sound::UI.const_defined?(name, false)).to eq(false), "MB::Sound::UI::#{name}"
    end
    %i[Cells ANSI].each do |name|
      expect(MB::Sound::Plot::Text.const_defined?(name, false)).to eq(false), "MB::Sound::Plot::Text::#{name}"
    end
    root = File.expand_path('../../../../..', __dir__)
    old = /\b(?:UI|ui)::(VT|Term|Screen|Input|Viewports|Themes|DataFile)\b|\bText::(Cells|ANSI)\b/
    hits = Dir[File.join(root, '{lib,bin,spec}/**/*.rb')].flat_map { |f|
      next [] if f == __FILE__

      File.readlines(f).each_with_index.filter_map { |l, i| "#{f.delete_prefix("#{root}/")}:#{i + 1}" if l.match?(old) }
    }
    expect(hits).to eq([]), "old names (use MB::Term::*): #{hits.first(10).join(', ')}"
  end

  it 'registers its native cells as the gem\'s native grid (the adapter)' do
    expect(MB::Term::Grid.native).to equal(MB::Sound::Plot::Text::NativeCells)
    expect(MB::Term::Grid.new(4, 2, native: true)).to be_a(MB::Sound::Plot::Text::NativeCells)
  end

  it "makes the C VT for MB::Term::VT.new, and RubyVT while the term_vt kernel is :ruby (the adapter)" do
    expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::NativeVT)
    expect(MB::Sound::Kernels[:term_vt].covers).to include('Term::FastTerm::VT')
    MB::Sound::Kernels.with(term_vt: :ruby) do
      expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::RubyVT)
    end
    MB::Sound::Kernels.with(:ruby) do
      expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::RubyVT)
      expect(MB::Term::Grid.new(2, 1)).to be_a(MB::Term::Cells)
    end
    expect(MB::Term::VT.new(2, 3)).to be_a(MB::Term::NativeVT)
  end

  it 'draws a VT the same into Cells and NativeCells (from the C VT: cells written directly into NativeCells, #put_run calls on Cells)' do
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
