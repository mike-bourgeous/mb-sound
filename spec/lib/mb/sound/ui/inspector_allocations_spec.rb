require_relative '../../../../support/ui_helpers'
require_relative '../../../../support/allocation_budget'

# The idle sound-design screen's garbage (sd-ux-fixes-1, the review's #7):
# with the inspector focused and nothing changing, the screen allocated about
# 145k objects a second (a GC every 2 s; 61k with the REPL focused, 2.6k in
# the plain console), most of it the status line's key hints rebuilt every
# frame (Keys.hints, mb-term Keymap#help_groups), then PaneKeys.kind_of, the
# inspector's shown_params, and its pick list.  This budget caps the objects
# a frame of a focused, idle inspector allocates (ALLOC_REPORT=1 prints the
# top sites; a failure names them).
RSpec.describe('the idle inspector\'s allocations', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  # Objects per frame, at most.  Measured 2026-11-13 on the Mac container:
  # 2210 before (master-ai 90e685fc), 443 after; 2026-11-16 (ui-wave-perf-1
  # round 3, Linux): 430 before, 192 after (the inspector's row tails,
  # headings, chain, and sections plan kept; frozen literals); ui-perf-2
  # round 3: 105 before (the zone lookup's imemos, Canvas#fit and #pad,
  # the rows, the picker, the status line), 17 after.
  FRAME_BUDGET = 20

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

  it 'allocates a few hundred objects a frame with the inspector focused and nothing changing' do
    MB::Sound::Session.with_context(session: @session) do
      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.bg(:bass, MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop)
    end
    4.times { @session.process_buffer }
    ui::Inspect.target = { track: :bass, node: nil }
    slow, = ui::Poll.new(@session).call([:inspect])
    knobs = @session.knobs.map { |n, k| ui::KnobValue.new(name: n, value: k.value, spec: k.spec) }.freeze
    # (a new snapshot every frame, as the painter's feed gives: time and
    # sequence move, the slow data and knobs stay)
    snaps = Array.new(200) { |i| ui_fake_snapshot(t: 1.0 + i / 60.0, seq: i + 1).with(slow: slow, knobs: knobs) }
    frame = 0
    @term = UIHelpers::FakeTerminal.new(40, 140)
    @tiles = ui::Tiles.new(layout: ui.tiles_layout_named(:sound), input: @term.slave, output: @term.slave, repl: :none,
                           probe: false, size: [40, 140], clock: -> { 1.0 + frame / 60.0 }, source: -> { snaps[frame % snaps.length] },
                           keyboard: ui::Keyboard.new(out: UIHelpers::NullKeyboardOut.new))
    @tiles.start(thread: false)
    @tiles.enter(:inspector)
    expect(@tiles.router.mode).to eq(:pane)
    40.times { frame += 1; @tiles.refresh } # (warm: caches, first draws)
    expect(@tiles.to_text).to include('dnb_reese').or(include('bass'))

    m = AllocationBudget.measure(buffers: 120) { frame += 1; @tiles.refresh }
    puts m.report(15) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= FRAME_BUDGET, m.report
  end
end
