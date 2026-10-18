require_relative '../../../../support/ui_helpers'

# The painter's guard (research-ui-2's test strategy): with a realtime
# Session rendering 256-frame buffers (the :low profile's 5.33 ms) on a
# paced NullOutput and the deck band painting at 60/s, the render thread's
# GVL waits (FastUI::GVLProbe) and the painter's CPU per refresh stay under
# budgets scaled by this machine's speed right now: a calibration run of the
# same painter, timed in the same process, so a slow or busy machine gets a
# proportionally larger budget instead of a flaky failure.
#
# Measured on the Mac container (i9-9880H, no YJIT, 2026-10-15): full deck
# redraw (calibration) 1.1-1.4 ms; render wait p99 0.18-0.29 ms, max 0.4; painter busy
# refresh p99 ~1 ms.  The budgets leave 5-10x.
RSpec.describe('UI painter timing', :aggregate_failures) do
  # A full deck redraw's median on the Mac container without YJIT (ms).
  REFERENCE_FULL_MS = 1.1

  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: true, buffer_size: 256) }
  let(:session) { MB::Sound::Session.new(output: output, realtime: true) }

  after do
    MB::Sound::FastUI::GVLProbe.stop
    @band&.stop
    session.close
    MB::Sound.rewind
  end

  # How much slower this machine is right now than the reference (at least 1).
  def slowdown
    band, = ui_fake_band(:deck, size: [40, 160])
    band.start(thread: false)
    times = 30.times.map { |i|
      band.invalidate
      t = MB::U.clock_now
      band.refresh(i * 0.01)
      (MB::U.clock_now - t) * 1000
    }.sort
    [times[times.length / 2] / REFERENCE_FULL_MS, 1.0].max
  end

  it 'keeps the render thread waiting for the GVL well under a buffer' do
    slow = slowdown

    # Six detuned saws through four-pole filters: a few percent of real time
    graph = 6.times.map { |i| (55 * (i + 2)).hz.saw.at(-24.db).lp4(800 + 300 * i, resonance: 0.3) }.reduce(:+)
    session.add(graph, name: :saws)
    Thread.pass until session.running?

    @band = MB::Sound::UI::Band.new(layout: MB::Sound::UI.layouts[:deck], io: File.open(File::NULL, 'w'), size: [40, 160], session: session, fps: 60)
    @band.start
    sleep 0.3 # first frames
    MB::Sound::FastUI::GVLProbe.start([session.render_thread, @band.thread])
    sleep 2.5
    MB::Sound::FastUI::GVLProbe.stop

    waits = MB::Sound::FastUI::GVLProbe.waits(0).sort
    stats = @band.stats
    p99 = waits[((waits.length - 1) * 0.99).round] * 1000
    busy = stats[:busy_cpu_ms][:p99]
    report = "slowdown #{slow.round(2)}, #{waits.length} waits, p99 #{p99.round(3)} ms, max #{(waits[-1] * 1000).round(3)} ms; " \
      "painter busy p99 #{busy} ms over #{stats[:frames]} refreshes; slowest #{stats[:slowest].first.inspect}"

    puts report if ENV["UI_TIMING_REPORT"] # the measured numbers
    expect(waits.length).to be > 300, report # it really ran (~470 buffers)
    expect(stats[:frames]).to be > 100, report
    expect(@band.feed.published).to be > 100, report
    expect(p99).to be < 2.0 * slow, report
    expect(busy).to be < 4.0 * slow, report
    # Structural: every pane drawn was followed by Thread.pass
    expect(stats[:yields]).to be >= stats[:frames] * stats[:panes] * 0.99
  end
end
