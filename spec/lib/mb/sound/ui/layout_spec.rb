require_relative '../../../../support/ui_helpers'

# Band layouts: placement, Ruby round trips, the safe loader, and saving.
RSpec.describe(MB::Sound::UI::Layout, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  it 'places rows and columns by fixed sizes and weights, with one blank column between panes' do
    l = described_class.new(:t) {
      cols { pane :transport; pane :form }
      cols { pane :tracks, width: 30; rows { pane :meters, height: 4; pane :knobs }; pane :scope }
    }
    placed = l.place(100).map { |p| [p.pane.name, p.x, p.y, p.w, p.h] }
    expect(placed).to eq([
      [:transport, 0, 0, 49, 1],
      [:form, 50, 0, 50, 1],
      [:tracks, 0, 1, 30, 10],
      [:meters, 31, 1, 29, 4],
      [:knobs, 31, 5, 29, 6],
      [:scope, 61, 1, 39, 10],
    ])
    # A row of columns is as tall as its tallest: the stack of meters (4)
    # and knobs (6)
    expect(l.height).to eq(11)
  end

  it 'prints itself back as Ruby that the loader reads (no eval)' do
    l = ui.layouts[:deck]
    text = l.to_ruby(at: :bottom)
    expect(text).to eq(<<~RUBY)
      layout :deck, at: :bottom do
        cols do
          pane :transport
          pane :form
        end
        cols do
          pane :tracks
          pane :queue
          pane :knobs
          pane :messages, only: :big
        end
        cols do
          pane :meters
          pane :cpu
          pane :scope
          pane :spectrum, only: :big
        end
      end
    RUBY
    back, opts = MB::Sound::UI::LayoutLoader.parse(text)
    expect(back.to_ruby(**opts)).to eq(text)
    expect(back.place(120).map { |p| [p.pane.name, p.x, p.y, p.w, p.h] }).to eq(l.place(120).map { |p| [p.pane.name, p.x, p.y, p.w, p.h] })
  end

  it 'refuses layout files that do anything but describe a layout' do
    loader = MB::Sound::UI::LayoutLoader
    [
      "system('touch x')",
      "layout :a do\n  system('x')\nend",
      "layout :a do\n  pane :tracks, height: `id`\nend",
      "layout :a do\n  pane File.read('x')\nend",
      "layout :a do\n  cols { pane :tracks }\nend\nlayout :b do\nend",
      "layout :a do\n  pane(:tracks).send(:x)\nend",
    ].each do |text|
      expect { loader.parse(text, 'x.rb') }.to raise_error(loader::LoadError, /x\.rb/), text
    end
  end

  it 'suggests pane and option names for typos' do
    expect { described_class.new(:t) { pane :trakcs }.place(80) }.to raise_error(ArgumentError, /No pane :trakcs.*did you mean :tracks\?/)
    expect { described_class.new(:t) { pane :tracks, hieght: 2 } }.to raise_error(ArgumentError, /Unknown layout option :hieght/)
    expect { described_class.new(:t) { pain :tracks } }.to raise_error(NoMethodError, /pain/)
    expect { ui.layout_named(:dek) }.to raise_error(ArgumentError, /No layout :dek \(did you mean :deck\?\)/)
  end

  it 'saves the band layout and shows it by name later' do
    dir = File.dirname(tmp_path('ui/x'))
    old = ENV['MB_SOUND_UI_DIR']
    ENV['MB_SOUND_UI_DIR'] = dir
    band, = ui_fake_band(:mini, at: :bottom)
    path = band.save(:my_mini)
    expect(path).to eq(File.join(dir, 'my_mini.rb'))
    expect(File.read(path)).to start_with('# mb-sound terminal UI layout').and include("layout :my_mini, at: :bottom do\n")
    expect(ui.saved_layouts).to eq([:my_mini])

    l = ui.layout_named(:my_mini)
    expect(l.pane_names).to eq(%i[transport form])
    expect(ui.layout_options[:my_mini]).to eq(at: :bottom)
  ensure
    ENV['MB_SOUND_UI_DIR'] = old
    ui.layouts.delete(:my_mini)
    ui.layout_options.delete(:my_mini)
  end
end
