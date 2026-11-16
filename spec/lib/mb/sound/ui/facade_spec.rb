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

    # (a bare `ui` with nothing on: the band when printed or a screen
    # command follows, not for ui.note; tuner-fixes-1)
    pending = MB::Sound.ui
    expect(pending).to be_a(ui::Pending)
    expect(pending.mode).to eq(:off)
    pending.notes
    expect(facade.mode).to eq(:off)
    expect(pending.inspect).to start_with('#<UI::Band')
    expect(MB::Sound.ui).to equal(facade) # (a screen on: the facade)
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

  it 'switches the live wave view with ui.waves, off by default' do
    expect(facade.waves).to eq(:off)
    expect(facade.waves(:live)).to eq(:live)
    expect(MB::Sound::UI::WaveView.live?).to eq(true)
    expect(facade.waves).to eq(:live)
    expect { facade.waves(:loud) }.to raise_error(ArgumentError, /one of \[:off, :live\]/)
  ensure
    MB::Sound::UI::WaveView.mode = :off
  end

  it 'turns every-buffer snapshots, snapshot-timed frames, and echo wake on and off together with ui.smooth, off by default (ui-perf-2)' do
    ui = MB::Sound::UI
    expect(facade.smooth).to eq(:off)
    expect(facade.smooth(:on)).to eq(:on)
    expect([ui::Feed.every_buffer, ui::FrameRate.snapshot_timed, ui::Tiles.echo_wake]).to eq([true, true, true])
    expect(facade.smooth).to eq(:on)
    t, tiles_term = ui_tiles(:tiles)
    allow(facade).to receive(:screen).and_return(t)
    expect(t.instance_variable_get(:@pacer).timing).to be_a(ui::FrameRate::SnapshotTiming)
    expect(facade.smooth(:off)).to eq(:off) # (the running screen too)
    expect(t.instance_variable_get(:@pacer).timing).to be_nil
    expect([ui::Feed.every_buffer, ui::FrameRate.snapshot_timed, ui::Tiles.echo_wake]).to eq([false, false, false])
    expect { facade.smooth(:fast) }.to raise_error(ArgumentError, /:on or :off/)
  ensure
    ui::Feed.every_buffer = ui::FrameRate.snapshot_timed = ui::Tiles.echo_wake = false
    t&.stop
    tiles_term&.close
  end

  it 'opens KEYS from the band with ui.keys (ux-1 round 3 item 8 bug: NoMethodError)' do
    keys_term = nil # (the KEYS screen's terminal, made in the stub below)
    term = UIHelpers::FakeTerminal.new(30, 100)
    MB::Sound.ui(:band)
    expect(facade.mode).to eq(:band)
    allow(ui).to receive(:show).and_wrap_original do |orig, name = nil, **opts|
      next orig.call(name, **opts) unless name == :keys
      ui.band&.stop
      t, keys_term = ui_tiles(:keys)
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
    keys_term&.close
  end
end
