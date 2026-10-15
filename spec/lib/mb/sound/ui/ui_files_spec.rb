require_relative '../../../../support/ui_helpers'

# The UI's data files: themes, pane files, and tiled layouts, read by
# walking their Prism trees (DataFile; never eval), reloaded by mtime.
RSpec.describe('UI data files', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:dir) { tmp_path('ui') }

  around do |ex|
    old = ENV['MB_SOUND_UI_DIR']
    ENV['MB_SOUND_UI_DIR'] = dir
    FileUtils.mkdir_p(File.join(dir, 'themes'))
    FileUtils.mkdir_p(File.join(dir, 'panes'))
    ex.run
  ensure
    ENV['MB_SOUND_UI_DIR'] = old
    ui::Themes.use(:default)
    ui::Themes.all.delete(:mine)
    %i[mix notes cutoff].each { |n| ui.panes.delete(n) }
    ui.tile_layouts.delete(:saved_one)
  end

  def write(rel, text, mtime: nil)
    path = File.join(dir, rel)
    File.write(path, text)
    File.utime(mtime, mtime, path) if mtime
    path
  end

  describe 'themes' do
    it 'loads a theme file with colors in every form and glyphs, based on another theme' do
      write('themes/mine.rb', <<~RUBY)
        theme :mine, based_on: :phosphor do
          role :title, '#102030', bold: true
          role :dim, 245
          role :warn, :bright_yellow
          role :key, [1, 2, 3]
          glyphs :unicode do
            play '⏵'
          end
        end
      RUBY
      t = ui::Themes.use(:mine)
      expect(t.roles[:title]).to eq([[16, 32, 48], true])
      expect(ui::Themes.rgb(:dim)).to eq(245)
      expect(ui::Themes.rgb(:warn)).to eq(11)
      expect(ui::Themes.rgb(:key)).to eq([1, 2, 3])
      expect(ui::Themes.rgb(:ok)).to eq(ui::Themes.all[:phosphor].roles[:ok][0])
      expect(ui::Themes.glyphs(:unicode)[:play]).to eq('⏵')
      expect(ui::Themes.glyphs(:unicode)[:rec]).to eq('●')
      expect(ui::Themes.glyphs(:ascii)[:play]).to eq('>')
      expect(ui::Themes.bold?(:title)).to eq(true)

      # Canvases draw with the theme: a palette index stays an index
      g = MB::Sound::Plot::Text::Cells.new(10, 1)
      ui::Canvas.new(g, 0, 0, 10, 1).text(0, 0, 'hi', :dim)
      expect(g.lines(:ansi256).first).to start_with("\e[38;5;245mhi")
    end

    it 'reloads the theme in use when its file changes' do
      write('themes/mine.rb', "theme :mine do\n  role :dim, 1\nend\n", mtime: Time.now - 10)
      ui::Themes.use(:mine)
      expect(ui::Themes.rgb(:dim)).to eq(1)
      write('themes/mine.rb', "theme :mine do\n  role :dim, 2\nend\n")
      expect(ui.reload_files[:theme]).to eq(true)
      expect(ui::Themes.rgb(:dim)).to eq(2)
    end

    it 'refuses code, unknown calls, and bad colors with the file and line' do
      write('themes/mine.rb', "theme :mine do\n  role :dim, 1\n  system 'ls'\nend\n")
      expect { ui::Themes.named(:mine) }.to raise_error(ui::DataFile::LoadError, /mine\.rb:3: `system` isn't allowed here/)
      write('themes/mine.rb', "theme :mine do\n  glyphs :unicode do\n    instance_eval 'x'\n  end\nend\n")
      expect { ui::Themes.named(:mine) }.to raise_error(ui::DataFile::LoadError, /mine\.rb:3: `instance_eval` isn't allowed/)
      write('themes/mine.rb', "theme :mine do\n  role :dim, :purpel\nend\n")
      expect { ui::Themes.named(:mine) }.to raise_error(ui::DataFile::LoadError, /No color :purpel/)
      write('themes/mine.rb', "theme :mine do\n  rol :dim, 1\nend\n")
      expect { ui::Themes.named(:mine) }.to raise_error(ui::DataFile::LoadError, /mine\.rb:2: `rol` isn't allowed here \(did you mean `role`\?\)/)
    end
  end

  describe 'pane files' do
    it 'defines panes from kinds with literal options, and reloads changed files' do
      write('panes/mine.rb', <<~RUBY, mtime: Time.now - 10)
        pane :mix, kind: :meters, title: 'mix', rate: 15
        pane :notes, kind: :text, lines: ['drop at 33', 'break at 49'], role: :name
        pane :cutoff, kind: :knob, knob: :cut
      RUBY
      r = ui.reload_files
      expect(r[:errors]).to eq([])
      expect(r[:panes]).to eq(%i[mix notes cutoff])
      expect(ui.panes[:mix]).to be_a(ui::Panes::Meters)
      expect([ui.panes[:mix].title, ui.panes[:mix].rate]).to eq(['mix', 15])
      expect(ui.panes[:notes].height).to eq(2)

      band, = ui_fake_band(ui::Layout.new(:files) { cols { pane :notes; pane :cutoff } }, size: [10, 60])
      band.refresh
      expect(band.to_text).to include('drop at 33', 'cut', '2400 Hz')

      expect(ui.reload_files[:panes]).to eq([]) # unchanged
      write('panes/mine.rb', "pane :notes, kind: :text, lines: ['new']\n")
      expect(ui.reload_files[:panes]).to eq([:notes])
      expect(ui.panes[:notes].height).to eq(1)
    end

    it 'keeps the old panes and reports errors with the line' do
      write('panes/bad.rb', "pane :mix, kind: :meterz\n")
      r = ui.reload_files
      expect(r[:errors].first).to match(/bad\.rb:1: No pane kind :meterz \(did you mean :meters\?\)/)
      write('panes/bad.rb', "pane :mix, kind: :meters, rate: `ls`\n", mtime: Time.now + 5)
      expect(ui.reload_files[:errors].first).to match(/bad\.rb:1: only literal values/)
    end

    it 'takes pane kinds defined in Ruby' do
      ui.pane_kind(:clock_spec) { |name, **o| ui::Pane.new(name, height: 1, **o) { |c, s| c.puts [s&.stamp.to_s, :key] } }
      write('panes/clock.rb', "pane :notes, kind: :clock_spec, rate: 2\n")
      expect(ui.reload_files[:panes]).to eq([:notes])
      expect(ui.panes[:notes].rate).to eq(2)
    ensure
      ui::PaneFiles.kinds.delete(:clock_spec)
    end
  end

  describe 'tiled layouts' do
    it 'saves the tree with ui.save and loads it back by name as a tiled layout' do
      tiles = ui::Tiles.new(layout: ui.tile_layouts[:studio], input: File.open(File::NULL), output: File.open(File::NULL, 'w'), size: [40, 120], repl: :thread)
      tiles.tiler.resize(:repl, :right, 3)
      path = tiles.save(:saved_one)
      expect(File.read(path)).to include('layout :saved_one, focus: :repl do', 'repl', 'tabs :meters, :knobs, :cpu')
      ui.tile_layouts.delete(:saved_one)
      l = ui.layout_named(:saved_one)
      expect(l).to be_a(ui::Viewports::Layout)
      expect(l.root).to eq(tiles.tiler.layout.root)
      expect(ui.saved_layouts).to include(:saved_one)
    end

    it 'defines tiled layouts with `layout` when they have a repl pane' do
      l = MB::Sound.layout(:spec_tiled, focus: :repl) { cols { repl; pane :meters, width: 30 } }
      expect(l).to be_a(ui::Viewports::Layout)
      expect(ui.tile_layouts[:spec_tiled]).to eq(l)
      band = MB::Sound.layout(:spec_band) { cols { pane :transport; pane :meters } }
      expect(band).to be_a(ui::Layout)
    ensure
      ui.tile_layouts.delete(:spec_tiled)
      ui.layouts.delete(:spec_band)
    end
  end
end
