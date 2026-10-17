require_relative '../../../../support/ui_helpers'

# The `ui` facade (ux-1 round 3 item 8): the same public surface with the
# tiled screen, the band, or nothing on screen.
RSpec.describe(MB::Sound::UI::Facade, :aggregate_failures) do
  let(:facade) { MB::Sound::UI.facade }
  let(:ui) { MB::Sound::UI }

  around do |example|
    old = $stdout
    $stdout = StringIO.new
    example.run
  ensure
    ui.off
    ui.instance_variable_set(:@tiles, nil)
    $stdout = old
  end

  # Public methods of either screen, as `ui.x` reaches them.
  let(:surface) { (ui::Tiles.public_instance_methods(false) | ui::Band.public_instance_methods(false)).reject { |m| m.end_with?('=') } }

  it 'answers every public Tiles and Band method in every mode, saying what to do where a method is the other screen\'s' do
    expect(facade.mode).to eq(:off)
    surface.each { |m| expect(facade.respond_to?(m)).to eq(true), m.to_s }
    # Off: Tiles-only and Band-only methods explain instead of raising
    (surface - %i[keys]).each do |m|
      expect { facade.public_send(m) }.not_to raise_error, "off: ui.#{m}"
    end
    expect($stdout.string).to include('ui.split: a screen\'s: none is on')

    band = MB::Sound.ui
    expect(band).to equal(facade)
    expect(facade.mode).to eq(:band)
    expect(facade.screen).to be_a(ui::Band)
    tiles_only = ui::Tiles.public_instance_methods(false) - ui::Band.public_instance_methods(false) - %i[keys start stop hide refresh pump]
    tiles_only.each do |m|
      $stdout.truncate(0)
      expect { facade.public_send(m) }.not_to raise_error, "band: ui.#{m}"
    end
    expect { facade.split }.to output(/ui.split: the tiled screen's/).to_stdout
    expect(facade.layout.name).to eq(:band) # (the band's own)
    expect(facade.inspect).to start_with('#<UI::Band')
  end

  it 'opens KEYS from the band with ui.keys (ux-1 round 3 item 8 bug: NoMethodError)' do
    term = UIHelpers::FakeTerminal.new(30, 100)
    MB::Sound.ui(:band)
    expect(facade.mode).to eq(:band)
    allow(ui).to receive(:show).and_wrap_original do |orig, name = nil, **opts|
      next orig.call(name, **opts) unless name == :keys
      ui.band&.stop
      t, = ui_tiles(:keys)
      ui.instance_variable_set(:@tiles, t)
      t
    end
    t = facade.keys
    expect(t).to be_a(ui::Tiles)
    expect(facade.mode).to eq(:tiles)
    expect(t.router.mode).to eq(:grab)
    expect(facade.split).to equal(t) # tiles commands now reach the tiles
  ensure
    ui.tiles&.stop
    term&.close
  end
end
