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
  # watched values move every frame (+values+ gives them for frame k,
  # written straight into the tap's newest slot, as Tap#publish writes
  # them, which allocates nothing).  Returns [move, draw] lambdas.
  def live_frames(node, kind, display, values)
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
    wv.target = wv::Target.new(label: 'row', kind: kind, watch: watch, keys: keys, view: display)
    pane = MB::Sound::UI::Panes::Preview.new
    grid = MB::Sound::Plot::Text::NativeCells.new(60, 12)
    canvas = MB::Sound::UI::Canvas.new(grid, 0, 0, 60, 12)
    state = {}
    ring = tap.instance_variable_get(:@values)
    slots = tap.instance_variable_get(:@slot_watch)
    k = 0
    move = lambda {
      k += 1
      s = (tap.seq + 1) % wv::Tap::SLOTS
      i = 0
      while i < keys.length
        ring[s * wv::Tap::MAX + i] = values.(k, i)
        i += 1
      end
      slots[s] = watch
      tap.instance_variable_set(:@seq, tap.seq + 1)
    }
    draw = -> { move.(); pane.draw(canvas, snap, state) }
    10.times { draw.() }
    expect(pane.priority).to eq(:live)
    [move, draw]
  end

  # Objects a live frame allocates beyond moving the values.
  def frame_objects(move, draw)
    m = AllocationBudget.measure(buffers: 80, &draw)
    base = AllocationBudget.measure(buffers: 80, &move)
    puts m.report(10) if ENV['ALLOC_REPORT']
    [m.objects_per_buffer - base.objects_per_buffer, m]
  end

  # (measured 2026-11-16 on the 7950X, values moving every frame: 0
  # objects a frame for every kind, 0.012-0.031 ms; before round 2 of
  # ui-wave-perf-1: 40 for a PWM cycle, 39 wavetable, 20 LFO, 173 four-pole)
  {
    'a PWM oscillator cycle' => [-> { MB::Sound::Tone.new(wave_type: :square, frequency: 110).pwm(0.3.constant) }, :tone,
                                 ->(k, i) { [110.0, 0.1 + 0.8 * (k % 40) / 40.0, Float::NAN][i] }],
    'a wavetable cycle' => [-> { MB::Sound::Tone.new(wave_type: :sine, frequency: 110).wavetable(:basic_norm, scan: 0.5.constant) }, :tone,
                            ->(k, i) { [110.0, Float::NAN, (k % 40) / 40.0][i] }],
    'an LFO with its marker' => [-> { 0.5.hz.triangle.lfo }, :lfo, ->(k, i) { [0.5, Float::NAN, Float::NAN, (k % 97) / 97.0][i] }],
    'a four-pole response' => [-> { 110.hz.saw.lp4(800.constant, resonance: 0.4) }, :four_pole, ->(k, i) { [300.0 * 2**(4 * (k % 40) / 40.0), 0.4][i] }],
    'an SVF peak response' => [-> { 110.hz.saw.filter(:peak, cutoff: 800.constant, quality: 2.0, gain: 4.0) }, :svf,
                               ->(k, i) { [300.0 * 2**(4 * (k % 40) / 40.0), 2.0, 0.5 + (k % 30) / 5.0][i] }],
    'a diode ladder response' => [-> { 110.hz.saw.diode(800.constant, resonance: 0.6) }, :four_pole, ->(k, i) { [300.0 * 2**(4 * (k % 40) / 40.0), 0.6][i] }],
  }.each do |what, (make, kind, values)|
    it "draws #{what} that moves every frame allocating nothing, in a fraction of a millisecond" do
      node = make.call
      node.sample(64)
      display = wv::FILTER_KINDS.include?(kind) ? wv::FilterDisplay.new(node) : wv::ToneDisplay.new(node)
      expect(display.why).to be_nil
      move, draw = live_frames(node, kind, display, values)
      objects, m = frame_objects(move, draw)
      expect(objects).to be <= 0.1, m.report
      ms = median_ms(80, &draw)
      slow = slowdown
      expect(ms).to be <= 0.25 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
    end
  end

  it 'draws a cookbook biquad response that moves every frame with only its retuning\'s Array' do
    node = 110.hz.saw.filter(:lowpass, cutoff: 800.constant, quality: 3.0, structure: :biquad)
    node.sample(64)
    move, draw = live_frames(node, :biquad, wv::FilterDisplay.new(node), ->(k, i) { [300.0 * 2**(4 * (k % 40) / 40.0), 3.0][i] })
    objects, m = frame_objects(move, draw)
    # (FastSound.cookbook returns the new coefficients as an Array: 1-2
    # objects on frames whose cutoff moved)
    expect(objects).to be <= 2.5, m.report
  end

  it 'draws an envelope with its moving playhead allocating nothing' do
    env = MB::Sound::Envelope.new(attack: 0.01, decay: 0.3, sustain: 0.6, release: 0.4, sample_rate: 48000)
    live = { stage: :segment, segment: 1, position: 0.1, peak: 1.0, at: MB::Sound::UI::Panes::Preview.now }.freeze
    node = MB::Sound::UI::Inspect::NodeInfo.new(key: 0, label: 'amp env', role: :env, count: 1, params: env.param_snapshot, preview: nil, knobs: [].freeze, live: live)
    info = MB::Sound::UI::Inspect::InspectInfo.new(track: :t, tracks: [:t].freeze, knobs: [].freeze, nodes: [node].freeze, node: 0, code: nil, error: nil)
    snap = MB::Sound::UI::Snapshot.fake.then { |s| s.with(slow: s.slow.with(inspector: info)) }
    pane = MB::Sound::UI::Panes::Preview.new
    canvas = MB::Sound::UI::Canvas.new(MB::Sound::Plot::Text::NativeCells.new(60, 12), 0, 0, 60, 12)
    state = {}
    wv.mode = :live
    draw = -> { pane.draw(canvas, snap, state) }
    10.times { draw.() }
    expect(pane.priority).to eq(:live)
    m = AllocationBudget.measure(buffers: 80, &draw)
    # (measured 2026-11-16: 0 objects, 0.016 ms; 3 before round 2)
    expect(m.objects_per_buffer).to be <= 0.1, m.report
    ms = median_ms(80, &draw)
    slow = slowdown
    expect(ms).to be <= 0.25 * slow, "#{ms.round(4)} ms at slowdown #{slow.round(2)}"
  end
end
