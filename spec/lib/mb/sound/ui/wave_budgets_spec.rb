require_relative '../../../../support/allocation_budget'

# Time and allocation budgets for the wave displays (ui-wave-perf-1): the
# :plot_wave kernel, Plot::Live redraws of previews whose title moves, and
# the live preview pane's frame (UI::WaveView), so a slower kernel or a
# display that starts allocating fails here instead of costing frames.
# Times are thread CPU medians scaled by this machine's speed against a
# fixed workload measured on the Linux desktop (7950X); objects are counted
# exactly (ALLOC_REPORT=1 prints the top sites).
RSpec.describe('wave display budgets', :aggregate_failures) do
  let(:wv) { MB::Sound::UI::WaveView }

  after do
    wv.mode = :off
    wv.target = nil
    wv.feed = nil
  end

  # The fixed workload's thread CPU on the reference machine (ms).
  REFERENCE_MS = 0.9

  def cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)

  # Median thread CPU (ms) of +n+ calls of the block.
  def median_ms(n = 60)
    3.times { yield }
    t = Array.new(n) { c = cpu; yield; (cpu - c) * 1000 }.sort
    t[n / 2]
  end

  # How much slower this machine is than the reference (at least 1).
  def slowdown
    work = -> { a = Numo::SFloat.new(20_000).seq; s = 0.0; 2000.times { |i| s += (i * 0.5) % 3 }; (a * 2 + 1).sum + s }
    [median_ms(15, &work) / REFERENCE_MS, 1.0].max
  end

  it 'draws a 120x30 wave from 2048 points in the kernel in a few microseconds, allocating nothing' do
    g = MB::Sound::Plot::Text::NativeCells.new(120, 30)
    data = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.linspace(0, 6.28, 2048)))
    ms = median_ms(200) { MB::Sound::FastUI.wave(g, data, 0, 0, 120, 30, -1.0, 1.0, 0xffffff, 10, 0x808080) }
    slow = slowdown
    # (measured 2026-11-16 on the 7950X: ~0.01 ms)
    expect(ms).to be <= 0.05 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
    m = AllocationBudget.measure(buffers: 100) { MB::Sound::FastUI.wave(g, data, 0, 0, 120, 30, -1.0, 1.0, 0xffffff, 10, 0x808080) }
    expect(m.objects_per_buffer).to be <= 0.2, m.report # (the measuring loop's own few objects)
  end

  it 'keeps a preview\'s layout while only its title moves (an lp4 cutoff under an LFO)' do
    f = 110.hz.saw.lp4(1200 * 2 ** 1.5.hz.lfo, resonance: 0.4)
    3.times { f.sample(800) }
    params = f.param_snapshot
    charts = (0...16).map { |k|
      cut = 300.0 * 2**(k / 4.0)
      b = MB::Sound::Plot::ChartBuilder.new(title: nil, x: nil, y: nil, legend: false, grid: true)
      MB::Sound::Plot::Panels.preview(f.class, params.with(preview: params.preview.merge(cutoff: cut, label: "lp4 ~#{cut.round} Hz reso 0.4")), b)
      b.build
    }
    live = MB::Sound::Plot::Live.new(width: 60, height: 12, look: :scope)
    grid = MB::Sound::Plot::Text::NativeCells.new(60, 12)
    i = 0
    16.times { live.draw(charts[(i += 1) % 16], grid, x: 0, y: 0) }
    m = AllocationBudget.measure(buffers: 64) { live.draw(charts[(i += 1) % 16], grid, x: 0, y: 0) }
    puts m.report(10) if ENV['ALLOC_REPORT']
    # (measured 2026-11-16: 164 objects; 1023 before the title-only redraw)
    expect(m.objects_per_buffer).to be <= 300, m.report
    expect(live.layouts).to eq(1)
    ms = median_ms(64) { live.draw(charts[(i += 1) % 16], grid, x: 0, y: 0) }
    slow = slowdown
    # (measured: 0.054 ms; 0.205 before)
    expect(ms).to be <= 0.15 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
  end

  # The live preview pane's frame for +node+ (a Tone or four-pole) whose
  # watched values the tap publishes, the published values moving each
  # frame through +move+.
  def live_frames(node, kind, display, move)
    feed = MB::Sound::UI::Feed.new
    tap = feed.wave_tap = wv::Tap.new
    keys = wv::KEYS.fetch(kind)
    watch = keys.map { |k| [node, k].freeze }.freeze
    tap.watch = watch
    wv.feed = feed
    wv.mode = :live
    info_node = MB::Sound::UI::Inspect::NodeInfo.new(key: 0, label: 'row', role: :osc, count: 1, params: node.param_snapshot, preview: nil, knobs: [].freeze)
    info = MB::Sound::UI::Inspect::InspectInfo.new(track: :t, tracks: [:t].freeze, knobs: [].freeze, nodes: [info_node].freeze, node: 0, code: nil, error: nil)
    snap = MB::Sound::UI::Snapshot.fake.then { |s| s.with(slow: s.slow.with(inspector: info)) }
    wv.target = wv::Target.new(label: 'row', kind: kind, watch: watch, keys: keys, display: display)
    pane = MB::Sound::UI::Panes::Preview.new
    grid = MB::Sound::Plot::Text::NativeCells.new(60, 12)
    canvas = MB::Sound::UI::Canvas.new(grid, 0, 0, 60, 12)
    state = {}
    k = 0
    -> { move.(k += 1); tap.publish; pane.draw(canvas, snap, state) }
  end

  it 'draws a live oscillator cycle that moves every frame in a fraction of a millisecond and a hundred-odd objects' do
    width = MB::Sound::GraphNode::Constant.new(0.3, smoothing: false, sample_rate: 48000)
    tone = MB::Sound::Tone.new(wave_type: :square, frequency: 110).pwm(width)
    tone.sample(64)
    frame = live_frames(tone, :tone, wv::ToneDisplay.new(tone), ->(k) { width.constant = 0.1 + 0.8 * (k % 40) / 40.0; tone.sample(32) })
    10.times { frame.call }
    m = AllocationBudget.measure(buffers: 80, &frame)
    puts m.report(10) if ENV['ALLOC_REPORT']
    # (measured 2026-11-16: ~120 objects a frame, the tone's sample and the title)
    expect(m.objects_per_buffer).to be <= 250, m.report
    ms = median_ms(80, &frame)
    slow = slowdown
    expect(ms).to be <= 0.5 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
  end

  it 'draws a live four-pole response that moves every frame in a fraction of a millisecond' do
    cut = MB::Sound::GraphNode::Constant.new(800.0, smoothing: false, sample_rate: 48000)
    f = 110.hz.saw.lp4(cut, resonance: 0.4)
    f.sample(64)
    frame = live_frames(f, :four_pole, wv::FilterDisplay.new(f), ->(k) { cut.constant = 300.0 * 2**(4 * (k % 40) / 40.0); f.sample(32) })
    10.times { frame.call }
    m = AllocationBudget.measure(buffers: 80, &frame)
    puts m.report(10) if ENV['ALLOC_REPORT']
    expect(m.objects_per_buffer).to be <= 400, m.report
    ms = median_ms(80, &frame)
    slow = slowdown
    expect(ms).to be <= 0.5 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
  end
end
