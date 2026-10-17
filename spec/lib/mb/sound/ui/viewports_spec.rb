RSpec.describe(MB::Sound::UI::Viewports, :aggregate_failures) do

  let(:studio) do
    MB::Sound::UI::Viewports.layout :studio, focus: :repl do
      pane :transport, height: 1
      cols do
        pane :tracks, width: 28
        rows weight: 2 do
          repl
          pane :journal, height: 8
        end
        tabs :meters, :scope, :spectrum, active: :scope
      end
    end
  end

  # Every pane inside the screen, non-empty, and no two overlapping.
  def expect_tiling(layout, w, h)
    placed = layout.place(w, h)
    rects = placed.map(&:rect)
    rects.each do |r|
      expect(r.w).to be > 0
      expect(r.h).to be > 0
      expect(r.x + r.w).to be <= w
      expect(r.y + r.h).to be <= h
    end
    rects.combination(2).each { |a, b| expect(a.overlap?(b)).to be(false), "#{a} overlaps #{b}" }
  end

  describe 'placement' do
    it 'places fixed sizes, weights, gaps, and the tab strip' do
      r = studio.rects(120, 40)
      expect(r[:transport]).to eq(MB::Sound::UI::Viewports::Rect.new(0, 0, 120, 1))
      expect(r[:tracks]).to eq(MB::Sound::UI::Viewports::Rect.new(0, 1, 28, 39))
      # 120 - 28 - 2 gaps = 90 shared 2:1
      expect(r[:repl]).to eq(MB::Sound::UI::Viewports::Rect.new(29, 1, 60, 30)) # a rule row below it
      expect(r[:journal]).to eq(MB::Sound::UI::Viewports::Rect.new(29, 32, 60, 8))
      expect(r[:scope]).to eq(MB::Sound::UI::Viewports::Rect.new(90, 2, 30, 38))
      expect(r).not_to have_key(:meters)
      strip = studio.place(120, 40).find(&:tabs)
      expect(strip.tabs).to eq(%i[meters scope spectrum])
      expect(strip.active).to eq(1)
      expect_tiling(studio, 120, 40)
    end

    it 'shows every built-in pane in the :wall layout at 200x60 (ux-1 item 13)' do
      rects = MB::Sound::UI.tile_layouts[:wall].rects(200, 59)
      expect(rects.keys).to include(:repl, *(MB::Sound::UI.panes.keys - MB::Sound::UI::ON_DEMAND_PANES.keys))
      rects.each_value { |r| expect(r.w * r.h).to be > 0 }
      expect(rects[:repl].w).to be >= 90
    end

    it 'shares by largest remainder, ties to the earlier child' do
      kids = [MB::Sound::UI::Viewports::Pane.new(name: :a), MB::Sound::UI::Viewports::Pane.new(name: :b), MB::Sound::UI::Viewports::Pane.new(name: :c)]
      expect(MB::Sound::UI::Viewports.shares(kids, 10)).to eq([4, 3, 3])
      expect(MB::Sound::UI::Viewports.shares(kids, 11)).to eq([4, 4, 3])
    end

    it 'honors min: by taking from the largest flexible sibling' do
      kids = [MB::Sound::UI::Viewports::Pane.new(name: :a, weight: 9), MB::Sound::UI::Viewports::Pane.new(name: :b, min: 5)]
      expect(MB::Sound::UI::Viewports.shares(kids, 20)).to eq([15, 5])
    end

    it 'shrinks overflowing fixed sizes from the end' do
      kids = [MB::Sound::UI::Viewports::Pane.new(name: :a, size: 8), MB::Sound::UI::Viewports::Pane.new(name: :b, size: 8)]
      expect(MB::Sound::UI::Viewports.shares(kids, 10)).to eq([8, 2])
    end

    it 'zooms one pane to the whole screen' do
      z = studio.with(zoom: :scope)
      expect(z.rects(80, 24)).to eq(scope: MB::Sound::UI::Viewports::Rect.new(0, 0, 80, 24))
    end
  end

  describe 'the DSL' do
    it 'rejects a width in rows, naming the fix' do
      expect { MB::Sound::UI::Viewports.layout(:x) { pane :a, width: 3 } }.to raise_error(MB::Sound::UI::Viewports::Error, /use height:/)
    end

    it 'suggests a method for a typo' do
      expect { MB::Sound::UI::Viewports.layout(:x) { colz { pane :a } } }.to raise_error(NoMethodError) { expect(_1.detailed_message).to include('Did you mean?  cols') }
    end

    it 'rejects duplicate pane names' do
      expect { MB::Sound::UI::Viewports.layout(:x) { pane :a; pane :a } }.to raise_error(MB::Sound::UI::Viewports::Error, /unique/)
    end
  end

  describe 'round trips' do
    it 'prints the declarative form' do
      expect(studio.to_ruby).to eq(<<~RUBY)
        layout :studio, focus: :repl do
          pane :transport, height: 1
          cols do
            pane :tracks, width: 28
            rows weight: 2 do
              repl
              pane :journal, height: 8
            end
            tabs :meters, :scope, :spectrum, active: :scope
          end
        end
      RUBY
    end

    it 'loads what it prints into an equal layout' do
      expect(MB::Sound::UI::Viewports::Loader.load(studio.to_ruby)).to eq(studio)
    end

    it 'prints tabs holding splits as a block' do
      l = MB::Sound::UI::Viewports.layout(:t) { tabs(active: 1) { pane :mix; cols { pane :a; pane :b, width: 10 } } }
      expect(l.to_ruby).to include("tabs active: 1 do\n    pane :mix\n    cols do")
      expect(MB::Sound::UI::Viewports::Loader.load(l.to_ruby)).to eq(l)
    end

    it 'refuses anything but layout calls and literals' do
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  system('ls')\nend\n") }.to raise_error(MB::Sound::UI::DataFile::LoadError, /system. isn't allowed here/)
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  pane :a, height: 1 + 1\nend\n") }.to raise_error(MB::Sound::UI::DataFile::LoadError, /only literal values/)
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x, evil: 1 do\n  pane :a\nend\n") }.to raise_error(MB::Sound::UI::DataFile::LoadError, /unknown layout option/)
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  pane :a, width: 3\nend\n") }.to raise_error(MB::Sound::UI::DataFile::LoadError, /use height:/)
    end
  end

  describe MB::Sound::UI::Viewports::Tiler do
    let(:t) { MB::Sound::UI::Viewports::Tiler.new(studio, 120, 40) }

    it 'splits beside (v) and below (s), focusing the new pane' do
      t.split(:repl, :cols, :knobs)
      expect(t.layout.focus).to eq(:knobs)
      expect(t.layout.to_ruby).to include("rows weight: 2 do\n      cols do\n        repl\n        pane :knobs\n      end\n      pane :journal, height: 8")
      t.split(:knobs, :rows)
      expect(t.layout.panes).to include(:empty1)
      expect_tiling(t.layout, 120, 40)
    end

    it 'splits a fixed pane in its own direction into two fixed halves' do
      t.split(:journal, :rows, :log)
      r = t.rects
      expect([r[:journal].h, r[:log].h]).to eq([4, 4])
    end

    it 'resizes exactly at the current size and round-trips the result' do
      before = t.rects
      t.resize(:repl, :right, 7)
      after = t.rects
      expect(after[:repl].w).to eq(before[:repl].w + 7)
      expect(after[:scope].w).to eq(before[:scope].w - 7)
      expect(after[:tracks]).to eq(before[:tracks])
      expect(t.layout.to_ruby).to include('rows weight: 67 do')
      expect(MB::Sound::UI::Viewports::Loader.load(t.layout.to_ruby)).to eq(t.layout)
    end

    it 'moves the far edge when there is no neighbor on that side' do
      before = t.rects
      t.resize(:scope, :right, 3)          # scope is last: its left edge moves right
      expect(t.rects[:scope].w).to eq(before[:scope].w - 3)
    end

    it 'resizes a fixed pane by changing its fixed size' do
      t.resize(:tracks, :right, 4)
      expect(t.layout.to_ruby).to include('pane :tracks, width: 32')
    end

    it 'resizes up and down inside rows' do
      t.resize(:journal, :up, 2)
      expect(t.rects[:journal].h).to eq(10)
    end

    it 'closes panes and collapses one-child splits' do
      t.split(:repl, :cols, :knobs).close(:knobs)
      expect(t.layout.root).to eq(studio.root)
      t.close(:journal)
      expect(t.layout.to_ruby).to include("    repl weight: 2\n")
    end

    it 'undoes and redoes like winner-mode' do
      t.split(:repl, :cols, :knobs).resize(:knobs, :left, 5).zoom(:knobs)
      expect(t.undo.undo.undo.layout).to eq(studio)
      expect(t.redo.layout.panes).to include(:knobs)
    end

    it 'swaps panes keeping the slots' do
      t.swap(:tracks, :repl)
      expect(t.rects[:repl]).to eq(studio.rects(120, 40)[:tracks])
    end

    it 'cycles tabs and shows another pane in a slot' do
      t.tab(1, :scope)
      expect(t.rects).to have_key(:spectrum)
      t.show(:clips, at: :tracks)
      expect(t.layout.to_ruby).to include('pane :clips, width: 28')
    end

    it 'numbers panes in reading order for NAV mode' do
      expect(t.numbered).to eq(%i[transport tracks repl scope journal])
    end

    it 'keeps every random edit sequence tiled and round-trippable' do
      rng = Random.new(42)
      200.times do
        names = t.layout.panes
        case rng.rand(6)
        when 0 then t.split(names.sample(random: rng), %i[rows cols].sample(random: rng)) if names.length < 14
        when 1 then t.close(names.sample(random: rng)) if names.length > 2
        when 2 then t.resize(names.sample(random: rng), MB::Sound::UI::Viewports::Tiler::DIRS.keys.sample(random: rng), rng.rand(1..6))
        when 3 then t.swap(*names.sample(2, random: rng))
        when 4 then t.equalize(names.sample(random: rng))
        when 5 then t.undo
        end
        expect_tiling(t.layout, 120, 40)
        expect(MB::Sound::UI::Viewports::Loader.load(t.layout.to_ruby)).to eq(t.layout)
      end
    end
  end


  describe 'more Tiler operations' do
    let(:t) { MB::Sound::UI::Viewports::Tiler.new(studio, 120, 40) }

    it 'focuses by direction and by number, and cycles focus' do
      t.focus!(:repl)
      expect(t.focus_dir(:left).focus).to eq(:tracks)
      expect(t.focus_dir(:right).focus).to eq(:repl)
      expect(t.focus_dir(:down).focus).to eq(:journal)
      expect(t.focus_dir(:up).focus).to eq(:repl)
      expect(t.focus_dir(:up).focus).to eq(:transport)
      expect(t.focus_index(4).focus).to eq(:scope)
      expect(t.focus_next.focus).to eq(:journal)
      expect(t.focus_next.focus).to eq(:transport)
      expect(t.undo?).to eq(false) # focus isn't an undo step
    end

    it 'shows a pane already on screen by swapping' do
      t.show(:repl, at: :tracks)
      expect(t.rects[:repl]).to eq(studio.rects(120, 40)[:tracks])
      expect(t.focus).to eq(:repl)
    end

    it 'names missing panes with a suggestion' do
      expect { t.zoom(:jornal) }.to raise_error(MB::Sound::UI::Viewports::Error, /did you mean :journal/)
    end

    it 'keeps pane options through edits, saving, and loading' do
      l = MB::Sound::UI::Viewports.layout(:o) { cols { repl; pane :scope, width: 30, look: :scope, rate: 30, title: 'mix' } }
      expect(l.to_ruby).to include('pane :scope, width: 30, look: :scope, rate: 30, title: "mix"')
      expect(MB::Sound::UI::Viewports::Loader.load(l.to_ruby)).to eq(l)
      expect(l.place(80, 20).find { |p| p.name == :scope }.opts).to eq(look: :scope, rate: 30, title: 'mix')
      t2 = MB::Sound::UI::Viewports::Tiler.new(l, 80, 20).swap(:repl, :scope)
      expect(t2.layout.options_of(:scope)).to eq(look: :scope, rate: 30, title: 'mix')
      expect { MB::Sound::UI::Viewports.layout(:o) { pane :a, look: Object.new } }.to raise_error(MB::Sound::UI::Viewports::Error, /literals/)
    end

    it 'reports the loader line and suggests calls' do
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  pane :a\n  colz do\n    pane :b\n  end\nend\n", 'x.rb') }
        .to raise_error(MB::Sound::UI::DataFile::LoadError, /x\.rb:3: `colz` isn't allowed here \(did you mean `cols`\?\)/)
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  pane :a, Foo\nend\n", 'x.rb') }.to raise_error(MB::Sound::UI::DataFile::LoadError, /x\.rb:2: constant Foo/)
      expect { MB::Sound::UI::Viewports::Loader.load("layout :x do\n  pane :a, height: -1\nend\n", 'x.rb') }.to raise_error(MB::Sound::UI::DataFile::LoadError, /x\.rb:2: Sizes are positive/)
    end
  end
end
