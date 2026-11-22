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

  # konsole-pacing (2026-11-21): `ui.perf :stop` returned the UI::Perf,
  # whose rings Pry printed as 209 000 lines; he typed `ui.perf.report` too
  it 'prints one line for every ui.perf action and takes ui.perf.report' do
    require 'pp'
    t, tiles_term = ui_tiles(:tiles)
    allow(facade).to receive(:screen).and_return(t)
    st = facade.perf(:start)
    expect(st).to be_a(ui::Facade::PerfStatus)
    expect(st.pretty_inspect.lines.length).to eq(1)
    expect(st.inspect).to start_with('ui.perf: recording')
    expect(facade.perf.inspect).to match(/\Aui\.perf: recording [\d.]+ s/) # (no argument while recording: a status line, no report)
    expect($stdout.string).not_to include('UI frame instruments')
    expect(facade.perf.report.inspect).to start_with('ui.perf: recording')
    expect($stdout.string.scan('UI frame instruments').length).to eq(1)
    stop = facade.perf.stop
    expect(stop.inspect).to match(/\Aui\.perf: stopped after [\d.]+ s/)
    expect($stdout.string.scan('UI frame instruments').length).to eq(2)
    expect(ui.last_perf.pretty_inspect.lines.length).to eq(1)
    expect(ui.last_perf.inspect).to match(/\A#<MB::Sound::UI::Perf stopped, \d+ frames>\z/)
    expect(facade.perf(:cancel).inspect).to eq('ui.perf: no capture is running')
    expect { facade.perf(:reprot) }.to raise_error(ArgumentError, /did you mean :report\?/)
  ensure
    t&.stop
    tiles_term&.close
  end

  it 'refuses a mistyped ui.smooth or ui.pace with a did-you-mean (his `ui.smooth :omn`), and sets the pacing on the running screen' do
    expect { facade.smooth(:omn) }.to raise_error(ArgumentError, /got :omn; did you mean :on\?/)
    expect(ui::Feed.every_buffer).to eq(false)
    expect { facade.pace(:termnal) }.to raise_error(ArgumentError, /did you mean :terminal\?/)
    expect(facade.pace).to eq(:terminal) # (the default since pace-default-1)
    t, tiles_term = ui_tiles(:tiles)
    allow(facade).to receive(:screen).and_return(t)
    pacer = t.instance_variable_get(:@pacer)
    expect(pacer.min_gap).to be_nil # (the specs' model terminal: no identity, no gap)
    t.terminal_profile = ui::TerminalProfile.konsole_bulk
    expect(pacer.min_gap).to be_within(1e-9).of(0.012)
    expect(facade.pace(:exact)).to eq(:exact)
    expect(pacer.min_gap).to be_nil
    expect(facade.pace(:terminal)).to eq(:terminal)
    expect(pacer.min_gap).to be_within(1e-9).of(0.012)
    t.terminal_profile = ui::TerminalProfile.konsole_sync # (Konsole 26.04 shows each synchronized frame: no gap)
    expect(pacer.min_gap).to be_nil
  ensure
    ui::FrameRate.pace = :terminal
    t&.stop
    tiles_term&.close
  end

  # pace-default-1 (the maintainer, 2026-11-21: "Pace by default: On older
  # Konsole keep writes at least 12 ms apart automatically"): the default
  # paces by the detected terminal; only Konsole before 26.04 has a gap, so
  # on every other terminal the painter runs exactly as with :exact (the
  # pacing reaches it only through Pacer#min_gap, nil there).
  it 'paces by default by the terminal identity: a 12 ms gap on Konsole before 26.04 only, nothing on other terminals' do
    expect(ui::FrameRate.pace).to eq(:terminal)
    t, tiles_term = ui_tiles(:tiles)
    pacer = t.instance_variable_get(:@pacer)
    {
      'Konsole 23.08.5' => 0.012, 'Konsole 25.12.0' => 0.012, 'Konsole 26.04.1' => nil,
      'kitty(0.39.1)' => nil, 'foot(1.16.2)' => nil, 'iTerm2 3.5.10' => nil, 'WezTerm 20240203-110809-5046fc22' => nil,
      'XTerm(390)' => nil, 'tmux 3.4' => nil, nil => nil,
    }.each do |answer, gap|
      t.terminal_profile = ui::TerminalProfile.detect(xtversion: answer, env: {})
      expect(pacer.min_gap.nil? ? nil : pacer.min_gap.round(6)).to eq(gap), answer.inspect
    end
    t.terminal_profile = ui::TerminalProfile.detect(env: { 'KONSOLE_VERSION' => '230805' })
    expect(pacer.min_gap).to be_within(1e-9).of(0.012)
    t.terminal_profile = ui::TerminalProfile.detect(env: { 'KONSOLE_VERSION' => '230805', 'TMUX' => '/tmp/tmux-0/default,1,0' })
    expect(pacer.min_gap).to be_nil # (behind tmux: tmux repaints on its own terms)
  ensure
    t&.stop
    tiles_term&.close
  end

  it 'says once when the typed target is more than the terminal shows: paced by default, naming 60 and ui.pace :exact (pace-default-1)' do
    t, tiles_term = ui_tiles(:tiles)
    t.terminal_profile = ui::TerminalProfile.konsole_bulk('Konsole 23.08')
    ui::FrameRate.pace_noticed = false
    t.target_fps = 60
    t.target_fps = 83
    expect($stdout.string).to eq('')
    t.target_fps = 90
    expect($stdout.string).to include('Konsole before 26.04 shows at most about 83 frames a second: pacing writes; target 60 is the smoothest on a 120 Hz display; ui.pace :exact turns pacing off')
    n = $stdout.string.length
    t.target_fps = 240
    expect($stdout.string.length).to eq(n) # (once a process)
    # (with pacing off, where the target collapses: the konsole-pacing line)
    ui::FrameRate.pace = :exact
    ui::FrameRate.pace_noticed = false
    t.target_fps = 90
    expect($stdout.string.length).to eq(n)
    t.target_fps = 120
    expect($stdout.string).to include('Konsole 23.08 shows a frame only 10 ms after output stops, so at 120 fps it shows about 25 a second', 'ui.target_fps = 60', 'ui.pace :terminal')
    # (no gap, no line)
    ui::FrameRate.pace = :terminal
    ui::FrameRate.pace_noticed = false
    t.terminal_profile = ui::TerminalProfile.konsole_sync
    m = $stdout.string.length
    t.target_fps = 200
    expect($stdout.string.length).to eq(m)
  ensure
    ui::FrameRate.pace = :terminal
    ui::FrameRate.pace_noticed = false
    t&.stop
    tiles_term&.close
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
