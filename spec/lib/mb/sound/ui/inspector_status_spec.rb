require_relative '../../../../support/ui_helpers'

# The status line over a focused inspector (sd-ux-fixes-1): what the
# review's tasks read there.
RSpec.describe('the inspector\'s status line', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    ui::Inspect.target = nil
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
  end

  after do
    ui::Inspect.target = nil
    @tiles&.stop
    @term&.close
    @session&.close
    MB::Sound.rewind
  end

  # A :sound screen over track :bass playing +instrument+, the inspector in
  # its mode; the snapshot follows the session's knobs.
  def screen(instrument = :dnb_reese)
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:bass, instrument)
      MB::Sound.bg(:bass, MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop)
    end
    4.times { @session.process_buffer }
    ui::Inspect.target = { track: :bass, node: nil }
    poll = ui::Poll.new(@session)
    snap = -> {
      slow, = poll.call([:inspect])
      ui_fake_snapshot.with(slow: slow, knobs: @session.knobs.map { |n, k| ui::KnobValue.new(name: n, value: k.value, spec: k.spec) }.freeze)
    }
    @now = 1.0
    @term = UIHelpers::FakeTerminal.new(40, 140)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:sound), input: @term.slave, output: @term.slave, repl: :none,
                           probe: false, size: [40, 140], clock: -> { @now }, source: snap,
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @tiles.start(thread: false)
    @tiles.enter(:inspector)
    @tiles.refresh
  end

  def status = @tiles.to_text.lines.last.to_s

  def act(*a)
    @tiles.send(:pane_action, :inspector, *a)
    @now += 0.05
    @tiles.refresh
  end

  # The review's #10: after a section jump the jump's flash stayed about
  # 3.5 s (9 Down presses) over Enter's hint
  it 'shows Enter\'s hint at once when a key changes the pick after a jump\'s flash' do
    screen
    act(:section, :amp)
    expect(status).to match(/AMP /)
    act(:pick, 1)
    expect(status).to include('Enter: ')
    expect(status).not_to match(/AMP \w/)
  end
end
