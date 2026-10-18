require 'mb/sound'

# Adaptive pane rates (UI::PaneRates, ux-r4 item 2) with a fake clock and
# synthetic load: live panes at the target rate when the painter and the
# render thread have room, stepping down under load (lists first, meters
# and scopes last), list panes taking turns, and coming back when calm.
RSpec.describe(MB::Sound::UI::PaneRates, :aggregate_failures) do
  # Panes as [name, priority, own rate].
  def panes = [
    [:meters, :meter, 30], [:scope, :meter, 30], [:transport, :live, 30], [:knobs, :live, 15],
    [:tracks, :list, 8], [:queue, :list, 4], [:buses, :list, 4], [:clips, :list, 2],
  ]

  # Runs a painter at +fps+ for +seconds+ (fake clock) where each drawn pane
  # costs +pane_cost+ seconds (a Proc of the time for changing load) and
  # the render load is +render+ (a Proc of the time).  Returns the rates
  # object and each pane's draw count by second.
  def simulate(seconds, fps: 60, pane_cost: ->(_t) { 0.0002 }, render: ->(_t) { 0.2 }, rates: nil)
    @t ||= 0.0
    rates ||= described_class.new(fps, clock: -> { @t })
    drawn_at = {}
    counts = Hash.new { |h, k| h[k] = Hash.new(0) }
    levels = []
    stop = @t + seconds
    period = 1.0 / fps
    while @t < stop
      now = @t
      rates.begin_frame(now)
      cands = panes.filter_map do |name, pr, own|
        d = drawn_at[name]
        next [name, pr, Float::INFINITY] if d.nil?
        next unless rates.due?(pr, own, nil, d, now)
        [name, pr, (now - d) * rates.rate(pr, own)]
      end
      draw = rates.pick(cands)
      draw.each do |name|
        drawn_at[name] = now
        rates.drew(name, now)
        counts[name][now.floor] += 1
      end
      cost = draw.length * pane_cost.(now)
      rates.observe(cost, render.(now), now + cost)
      levels << rates.level
      @t = now + [period, cost].max
    end
    [rates, counts, levels]
  end

  def per_second(counts, name, second) = counts[name][second]

  it 'runs meters and live panes at the target rate and list panes at their own when there is room' do
    rates, counts, levels = simulate(5.0)
    expect(levels.uniq).to eq([0])
    expect(per_second(counts, :meters, 3)).to be_within(1).of(60)
    expect(per_second(counts, :transport, 3)).to be_within(1).of(60)
    expect(per_second(counts, :tracks, 3)).to be_within(1).of(8)
    expect(per_second(counts, :clips, 3)).to be_within(1).of(2)
    expect(rates.measured[:scope]).to be_within(1).of(60)
    expect(rates.readout).to eq('full rate')
    # A target of 30: live panes follow it (never below their own rate)
    rates2, counts2, = simulate(3.0, fps: 30)
    expect(per_second(counts2, :meters, @t.floor - 1)).to be_within(1).of(30)
    expect(rates2.rate(:live, 15)).to eq(30)
  end

  it 'steps down under painter load, slowing lists before meters, with turns, then recovers when idle' do
    # 3 ms per pane: about 8 panes * 3 ms per frame, well over half of a 16.7 ms period
    heavy = ->(t) { t < 4.0 ? 0.003 : 0.0001 }
    rates, counts, levels = simulate(14.0, pane_cost: heavy)
    peak = levels.max
    expect(peak).to be >= 3
    # Levels go one step at a time, at least STRAIN apart
    expect(levels.each_cons(2).all? { |a, b| (b - a).abs <= 1 }).to eq(true)
    # Under load the meters keep more of their rate than the lists
    s = 3
    expect(per_second(counts, :meters, s)).to be > per_second(counts, :transport, s)
    expect(per_second(counts, :meters, s) / 60.0).to be > per_second(counts, :tracks, s) / 8.0
    # Turns: at most one pane other than meters per frame at the top levels
    lvl = described_class::LEVELS[peak]
    expect(lvl.turns).to eq(1)
    # Recovery: back to full rate after the load ends (EASE per level)
    expect(levels.last).to eq(0)
    expect(per_second(counts, :meters, 13)).to be_within(1).of(60)
    expect(per_second(counts, :tracks, 13)).to be_within(1).of(8)
    expect(rates.changes).to eq(2 * peak)
  end

  it 'steps down for render-thread load even when painting is cheap, and holds while load is merely fine' do
    render = ->(t) { t < 2.0 ? 0.9 : t < 6.0 ? 0.7 : 0.1 }
    rates, _, levels = simulate(15.0, render: render)
    at2 = levels[(2.0 * 60).floor - 1]
    expect(at2).to be >= 2
    # 0.7: between calm and busy, the level holds (no flapping)
    expect(levels[(5.9 * 60).floor]).to eq(at2)
    expect(levels.last).to eq(0)
    expect(rates.readout).to eq('full rate')
  end

  it 'gives a list pane its turn eventually (most overdue first)' do
    r = described_class.new(60, clock: -> { 0.0 })
    r.instance_variable_set(:@level, 4)
    r.begin_frame
    picked = r.pick([[:meters, :meter, 2.0], [:tracks, :list, 1.5], [:queue, :list, 3.0], [:knobs, :live, 2.0]])
    expect(picked).to eq(%i[meters queue])
    expect(r.rate(:list, 4)).to eq(described_class::MIN_RATE)
    expect(r.rate(:meter, 30)).to eq(15.0)
  end

  it 'defines every (state, event) pair and moves only through the table' do
    described_class::STATES.product(described_class::EVENTS).each do |s, e|
      t = 0.0
      r = described_class.new(60, clock: -> { t })
      r.instance_variable_set(:@state, s)
      r.instance_variable_set(:@since, 0.0) unless s == :steady
      to, = described_class::TRANSITIONS.fetch([s, e])
      r.event!(e, 1.0)
      expect(r.state).to eq(to), "#{s} + #{e}"
    end
    expect(described_class.table.length).to eq(9)
    # Random walk: the level stays in range and changes by one at a time
    rng = Random.new(RSpec.configuration.seed)
    t = 0.0
    r = described_class.new(60, clock: -> { t })
    last = 0
    2000.times do
      t += rng.rand * 0.2
      r.event!(described_class::EVENTS.sample(random: rng), t)
      expect(r.level).to be_between(0, described_class::LEVELS.length - 1)
      expect((r.level - last).abs).to be <= 1
      expect(r.since.nil?).to eq(r.state == :steady)
      last = r.level
    end
  end

  it 'classes panes by kind, or by their own priority' do
    ui = MB::Sound::UI
    expect(described_class.priority_of(:meters, ui::Panes::Meters.new)).to eq(:meter)
    expect(described_class.priority_of(:mix, ui::Panes::Meters.new)).to eq(:meter)
    expect(described_class.priority_of(:tracks, ui::Panes::Tracks.new)).to eq(:list)
    expect(described_class.priority_of(:keyboard, nil)).to eq(:live)
    own = Class.new(ui::Pane) { def priority = :live }.new(:x)
    expect(described_class.priority_of(:x, own)).to eq(:live)
  end
end
