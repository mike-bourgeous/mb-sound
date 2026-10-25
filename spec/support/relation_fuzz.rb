# Relation fuzzing (test-tiers-1, 2026-10-25): a seeded generator of small
# random graphs, checked against relations that must hold for any graph
# (spec/lib/mb/sound/relation_fuzz_spec.rb):
#
# - :plan_exact: planned == unplanned, bit for bit, at Plan.precision :exact
#   (Synth lanes plan themselves, so "unplanned" is Plan.enabled = false)
# - :plan_fast: at the default :fast precision, the difference's RMS within
#   -60 dB of the signal's (sample by sample it isn't bounded; see #check)
# - :plan_check: Plan.install(check: :raise) (MB_SOUND_PLAN_CHECK's
#   comparison: every block planned, then unfused from restored state;
#   samples and node states compared)
# - :recipe: to_ruby(seeds: true), evaluated again, renders the same samples
# - :document: GraphIO.dump, then GraphIO.load, renders the same samples
# - :buffer_size: the same render at 800-sample and [367, 368] buffers
#   within -80 dB of the peak ("ears win": exactness is not the contract)
#
# Graphs are expression trees (Expr) printed as DSL Ruby (the repro is the
# code), evaluated in the MB::Sound context like the console.  A failure is
# shrunk (subtrees replaced by their children or a plain saw, modulated
# parameters by constants) while the same relation still fails, and
# reported with its seed and minimal graph:
#
#   FUZZ_SEED=1234 bundle exec rspec spec/lib/mb/sound/relation_fuzz_spec.rb
#   FUZZ=500 bundle exec rspec spec/lib/mb/sound/relation_fuzz_spec.rb   # the long mode
require_relative 'graph_sweep'
require_relative 'recipe_helpers'

module RelationFuzz
  RELATIONS = %i[plan_exact plan_fast plan_check recipe document buffer_size].freeze

  # Samples per render (a little over a 0.1 s, past the clips' first notes)
  FRAMES = 4800

  # Relations known to fail for a reason recorded elsewhere, as
  # { relation => [[Regexp on the code, 'reason'], ...] }: skipped, counted.
  # :fast sines driving discrete decisions: decimate's hold instants move
  # by a sample (steps up to 0.02), and sah's LFO clock fires on other
  # samples, so its random draws differ (RMS -15 dB); :exact is identical
  FAST_DECISIONS = [/decimate\(\d+\.hz\.lfo|sweep\("sample_hold"\)|\.sah\(/, ':fast sines feeding discrete decisions (test-tiers-1 report)'].freeze
  KNOWN = {
    plan_fast: [FAST_DECISIONS],
  }.freeze

  Expr = Struct.new(:kind, :args, :kids) do
    def to_s = RelationFuzz.code(self)

    def size = 1 + kids.sum(&:size)

    def stereo? = kind == :pan || kids.any?(&:stereo?)
  end

  Failure = Struct.new(:seed, :relation, :code, :message, :original, keyword_init: true) do
    def to_s
      "relation #{relation} fails for seed #{seed} (FUZZ_SEED=#{seed}); shrunk from #{original.length} to #{code.length} characters:\n\n" \
        "  #{code}\n\n#{message.to_s.lines.first(6).join}"
    end
  end

  SHAPES = %i[saw square triangle sine asaw asquare].freeze
  FILTERS = %i[lowpass highpass bandpass notch peak lowshelf highshelf allpass].freeze

  module_function

  # --- generation -----------------------------------------------------

  def generate(rng, depth = 0)
    leaf = depth >= 3 || rng.rand < 0.25 + 0.2 * depth
    return leaf(rng) if leaf

    case rng.rand(10)
    when 0, 1 then Expr.new(:add, [], [generate(rng, depth + 1), generate(rng, depth + 1)])
    when 2 then Expr.new(:mul, [], [generate(rng, depth + 1), generate(rng, depth + 1)])
    else unary(rng, generate(rng, depth + 1))
    end
  end

  # The graph sweep's factories (spec/support/graph_sweep.rb) as leaves, by
  # name, so every node type the sweep builds can meet the generator's steps
  def sweep_names
    @sweep_names ||= GraphSweep.factories.map(&:first).reject { |n| SWEEP_SKIP.any? { |re| n.match?(re) } }
  end

  # Factories left out of the leaves, and why
  SWEEP_SKIP = [
    /\Aknob moves/, # (knob moves are scheduled on absolute frames: a second build in one process sees them done)
    /\ABusTap/, # (reads Session buses: silence outside a Session)
    /\Acapture tap/, # (live capture plumbing)
  ].freeze

  # Sweep factories with complex outputs
  COMPLEX_SWEEPS = ['HilbertIIR', 'complex matrix (Analytic)'].freeze

  # A sweep factory's graph (the code's `RelationFuzz.sweep(name)`)
  def sweep(name)
    f = GraphSweep.factories.find { |n, _| n == name } or raise ArgumentError, "no graph sweep factory #{name.inspect}"
    g = f[1].call(GraphSweep::Context.new)
    g = g.mixdown if g.respond_to?(:mixdown) && g.respond_to?(:outputs) && g.outputs.length > 1
    # (complex signals into real-only steps are deliberate errors: clip says
    # "can't process complex data")
    COMPLEX_SWEEPS.include?(name) ? g.real : g
  end

  def leaf(rng)
    return Expr.new(:sweep, [sweep_names[rng.rand(sweep_names.length)]], []) if rng.rand < 0.3

    case rng.rand(10)
    when 0..4
      f = [55, 110, 147, 220, 331, 440, 1200][rng.rand(7)]
      shape = SHAPES[rng.rand(SHAPES.length)]
      mod = rng.rand < 0.3 ? [:fm, control(rng, -40, 40)] : (shape == :square && rng.rand < 0.4 ? [:pwm, control(rng, 0.1, 0.9)] : nil)
      Expr.new(:tone, [f, shape, mod], [])
    when 5 then rng.rand < 0.5 ? Expr.new(:noise, [rng.rand(1..9)], []) : Expr.new(:color, [%i[pink brown][rng.rand(2)]], [])
    when 6, 7
      Expr.new(:synth, [SHAPES.first(4)[rng.rand(4)], rng.rand(1..3), rng.rand < 0.5 ? control(rng, 300, 3000) : nil], [])
    when 8 then Expr.new(:drums, [%w[x.x. x... xx.x][rng.rand(3)], %w[.x.. ..x. .xx.][rng.rand(3)]], [])
    else Expr.new(:lfo_audio, [control(rng, -0.5, 0.5)], [])
    end
  end

  # A parameter: a number in lo..hi, or a slow LFO over it
  def control(rng, lo, hi)
    a = lo + (hi - lo) * rng.rand * 0.4
    b = hi - (hi - lo) * rng.rand * 0.4
    rng.rand < 0.5 ? [:const, ((a + b) / 2).round(3)] : [:lfo, [3, 7, 11, 23][rng.rand(4)], a.round(3), b.round(3)]
  end

  def unary(rng, kid)
    op =
      case rng.rand(18)
      when 0 then [:filter, FILTERS[rng.rand(FILTERS.length)], control(rng, 200, 5000), control(rng, 0.5, 4)]
      when 1 then [:lp4, control(rng, 200, 5000), rng.rand.round(2)]
      when 2 then [:diode, control(rng, 200, 4000), rng.rand.round(2)]
      when 3 then [:softclip]
      when 4 then [:asoftclip]
      when 5 then [:clip, (0.2 + rng.rand * 0.6).round(2)]
      when 6 then [:quantize, [0.05, 0.1, 0.25][rng.rand(3)]]
      when 7 then [:delay, control(rng, 0.0005, 0.004), rng.rand < 0.5 ? (rng.rand * 0.6).round(2) : nil]
      when 8 then [:decimate, control(rng, 800, 9000)]
      when 9 then [:at, control(rng, 0.2, 1.0)]
      when 10 then [:compress, -[6, 12, 20][rng.rand(3)], [2, 4, 8][rng.rand(3)]]
      when 11 then [:feedback, rng.rand(20..120), (0.2 + rng.rand * 0.5).round(2)]
      when 12 then [:ease, %i[smoothstep elastic bounce][rng.rand(3)]]
      when 13 then [:formant, %i[a e i o u][rng.rand(5)]]
      when 14 then [:pan, control(rng, -1, 1)]
      when 15 then rng.rand < 0.5 ? [:abs] : [:until, [0.011, 0.0313, 0.05][rng.rand(3)]]
      when 16 then [:period_delay, [110, 220, 331][rng.rand(3)]]
      # (per-channel triggers on a stereo input: same-shape channel
      # regions grouped over one pan's outputs; fuzz-fixes-1's lane group
      # rebuild bug)
      else [:sample_hold, kid.stereo? && rng.rand < 0.5]
      end
    # (a stereo bundle under a mono-only step: mix it down first)
    kid = Expr.new(:mixdown, [], [kid]) if kid.stereo? && %i[pan feedback].include?(op.first)
    Expr.new(op.first, op.drop(1), [kid])
  end

  # One Expr of every unary step kind (with typical arguments) over +kid+,
  # for checks that every step meets some input (complex values, ...).
  def every_unary(kid)
    c = [:const, 1000]
    [
      [:filter, :lowpass, c, [:const, 1]], [:lp4, c, 0.3], [:diode, c, 0.3], [:softclip], [:asoftclip], [:clip, 0.5],
      [:quantize, 0.1], [:delay, [:const, 0.001], nil], [:delay, [:const, 0.001], 0.3], [:decimate, [:const, 4000]],
      [:at, [:const, 0.5]], [:compress, -12, 4], [:feedback, 30, 0.5], [:ease, :smoothstep], [:formant, :a],
      [:pan, [:const, 0.2]], [:abs], [:until, 0.011], [:period_delay, 110], [:sample_hold, false],
    ].map { |op| Expr.new(op.first, op.drop(1), [kid]) }
  end

  # --- printing -------------------------------------------------------

  def ctl(c)
    c.first == :const ? c[1].to_s : "#{c[1]}.hz.lfo.at(#{c[2]}..#{c[3]})"
  end

  def code(e)
    k = e.kids.map { |x| code(x) }
    a = e.args
    case e.kind
    when :tone
      s = "#{a[0]}.hz.#{a[1]}"
      s += ".#{a[2][0]}(#{ctl(a[2][1])})" if a[2]
      "#{s}.at(0.5)"
    when :sweep then "RelationFuzz.sweep(#{a[0].inspect})"
    when :noise then "noise(seed: #{a[0]}).at(0.3)"
    when :color then "noise(#{a[0].inspect}).at(0.5)"
    when :synth
      cut = a[2] ? ".filter(:lowpass, cutoff: #{ctl(a[2])}, quality: 2)" : ''
      "seq(C4.n128, E4.n128, G4.n64, C5.n128).loop.synth(voices: #{a[1]}) { |v, _i| v.hz.#{a[0]}#{cut} * v.amp_env(0.001, 0.002, 0.5, 0.002) }"
    when :drums then "tr808(grid(32, bd: '#{a[0]}', snare: '#{a[1]}'))"
    when :complex then '220.hz.saw.hilbert_iir' # (only in relation_fuzz_spec's complex input check)
    when :lfo_audio then "(#{ctl(a[0])} + 220.hz.triangle.at(0.5))"
    when :add then "(#{k[0]} + #{k[1]})"
    when :mul then "(#{k[0]} * #{k[1]})"
    when :mixdown then "#{k[0]}.mixdown"
    when :filter then "#{k[0]}.filter(#{a[0].inspect}, cutoff: #{ctl(a[1])}, quality: #{ctl(a[2])}#{%i[peak lowshelf highshelf].include?(a[0]) ? ', gain: 2.0' : ''})"
    when :lp4 then "#{k[0]}.lp4(#{ctl(a[0])}, resonance: #{a[1]})"
    when :diode then "#{k[0]}.diode(#{ctl(a[0])}, resonance: #{a[1]})"
    when :softclip, :asoftclip, :abs then "#{k[0]}.#{e.kind}"
    when :until then "(#{k[0]}.until(#{a[0]}) + 110.hz.triangle.at(0.2))" # (an input ending inside a sum: eaa5e3ab's rings)
    when :period_delay then "#{k[0]}.delay(#{a[0]}.hz.period)" # (8cbe7f65: periods print exactly)
    when :clip then "#{k[0]}.clip(-#{a[0]}, #{a[0]})"
    when :quantize then "#{k[0]}.quantize(#{a[0]})"
    when :delay then "#{k[0]}.delay(#{ctl(a[0])}#{a[1] ? ", feedback: #{a[1]}, dry: 1" : ''})"
    when :decimate then "#{k[0]}.decimate(#{ctl(a[0])})"
    when :at then "#{k[0]}.at(#{ctl(a[0])})"
    when :compress then "#{k[0]}.compress(threshold: #{a[0]}.db, ratio: #{a[1]})"
    when :feedback then "#{k[0]}.feedback { |fb, input| input + fb.delay(#{a[0]}.samples) * #{a[1]} }"
    when :ease then "#{k[0]}.ease(#{a[0].inspect})"
    when :formant then "#{k[0]}.formant(#{a[0].inspect})"
    when :pan then "#{k[0]}.pan(#{ctl(a[0])})"
    when :sample_hold
      trig = 'seq(C4.n64, E4.n64).loop.notes.trigger'
      "#{k[0]}.sample_hold(#{a[0] ? "stereo(#{trig}, #{trig})" : trig})"
    else raise ArgumentError, "unknown kind #{e.kind}"
    end
  end

  # --- building and rendering -----------------------------------------

  def build(code)
    MB::Sound.rewind
    MB::Sound.seed(1)
    Numo::NArray.srand(1) # (factories that draw NArray#rand data)
    RecipeHelpers.eval_recipe(code)
  end

  # Renders +graph+'s outputs for FRAMES samples in buffers cycling through
  # +sizes+; returns one DFloat per output (shorter if it ended).
  def render(graph, sizes = [800], frames: FRAMES)
    outs = graph.respond_to?(:outputs) ? graph.outputs.to_a : [graph]
    bufs = outs.map { [] }
    n = 0
    i = 0
    while n < frames
      c = [sizes[i % sizes.length], frames - n].min
      done = false
      outs.each_with_index do |o, j|
        b = o.sample(c)
        next done = true if b.nil?

        b = b.real if b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex)
        bufs[j] << Numo::DFloat.cast(b)
      end
      break if done

      n += c
      i += 1
    end
    MB::Sound.rewind
    bufs.map { |b| b.empty? ? Numo::DFloat[] : Numo::DFloat.zeros(0).concatenate(*b) }
  end

  def with_plan(enabled: true, precision: nil)
    plan = MB::Sound::Plan
    old = [plan.enabled, plan.precision]
    plan.enabled = enabled
    plan.precision = precision if precision
    yield
  ensure
    plan.enabled, plan.precision = old
  end

  def compare(ref, got, tolerance: 0, label: '')
    return "#{label}: #{got.length} outputs, expected #{ref.length}" if ref.length != got.length

    ref.zip(got).each_with_index do |(r, g), i|
      return "#{label}: output #{i} has #{g.length} samples, expected #{r.length}" if r.length != g.length
      next if r.length == 0

      d = (r - g).abs
      worst = d.max
      return "#{label}: output #{i} is not finite where the reference is" if g.isfinite.count_false > r.isfinite.count_false
      next if worst <= tolerance

      idx = d.max_index
      return "#{label}: output #{i} differs by #{worst} (tolerance #{tolerance}) first at sample #{(d.gt(tolerance)).where[0]}, worst at #{idx} (#{g[idx]} vs #{r[idx]})"
    end
    nil
  end

  def peak(render) = render.map { |r| r.length == 0 ? 0.0 : r.abs.max }.max || 0.0

  # Checks +relation+ for +code+: nil if it holds, :skip if it doesn't apply
  # (a graph that can't print, a KNOWN case), else a failure message.
  def check(relation, code)
    return :skip if KNOWN.fetch(relation, []).any? { |re, _| code.match?(re) }

    case relation
    when :plan_exact, :plan_fast
      precision = relation == :plan_exact ? :exact : :fast
      ref = with_plan(enabled: false) { render(build(code)) }
      got = with_plan(precision: precision) {
        g = build(code)
        MB::Sound::Plan.install(g)
        render(g)
      }
      return compare(ref, got, label: 'planned (exact) vs unplanned') if relation == :plan_exact

      # :fast: the RMS of the difference within -60 dB of the signal's RMS.
      # Sample by sample it isn't bounded: FM by fast-sine LFOs drifts past
      # -100 dB within 0.1 s (errors accumulate in the modulated phases), and
      # thresholds after them (quantize, decimate's hold instants) turn
      # tiny differences into steps.
      problem = compare(ref, got, tolerance: Float::INFINITY, label: 'planned (fast) vs unplanned')
      return problem if problem

      ref.zip(got).each_with_index do |(r, g), i|
        next if r.length == 0

        rms = ->(x) { Math.sqrt((x * x).mean) }
        d = rms.(r - g)
        return "planned (fast) vs unplanned: output #{i} RMS difference #{d} over -60 dB of the RMS #{rms.(r)}" if d > 1e-3 * [rms.(r), 1e-3].max
      end
      nil
    when :plan_check
      with_plan(precision: :exact) {
        g = build(code)
        MB::Sound::Plan.install(g, check: :raise)
        render(g)
      }
      nil
    when :recipe
      g = build(code)
      text = g.to_ruby(seeds: true)
      return :skip if text.include?('FIXME') || text.start_with?('# inputs')

      ref = render(build(code))
      MB::Sound.rewind
      MB::Sound.seed(text.include?('MB::Sound.seed') ? 1 : 77)
      got = render(RecipeHelpers.eval_recipe(text))
      compare(ref, got, label: "to_ruby round trip\n#{text}")
    when :document
      g = build(code)
      text = MB::Sound::GraphIO.dump(g)
      return :skip if text.include?('FIXME')

      ref = render(build(code))
      MB::Sound.rewind
      MB::Sound.seed(77)
      got = render(MB::Sound::GraphIO.load(text))
      compare(ref, got, label: "GraphIO round trip\n#{text.lines.reject { |l| l.start_with?('#') }.join}")
    when :buffer_size
      ref = render(build(code), [800])
      got = render(build(code), [367, 368])
      compare(ref, got, tolerance: 1e-4 * [peak(ref), 1e-2].max, label: 'buffer sizes [367, 368] vs 800')
    end
  rescue MB::Sound::GraphIO::DumpError
    :skip # (graphs that can't be saved as plain documents yet: in-memory Samples, ...)
  rescue MB::Sound::GraphIO::LoadError, NotImplementedError => e
    relation == :document ? "GraphIO: #{e.class}: #{e.message}" : "#{e.class}: #{e.message}"
  rescue StandardError, SystemStackError => e
    "#{e.class}: #{e.message.lines.first(3).join} (#{e.backtrace&.find { |l| l.include?('/lib/mb/') }&.sub(/.*\/lib\//, 'lib/')})"
  end

  # --- shrinking ------------------------------------------------------

  # Smaller variants of +e+: each subtree replaced by one of its children
  # or a plain saw, modulated controls replaced by constants.
  def variants(e)
    out = []
    plain = Expr.new(:tone, [110, :saw, nil], [])
    out.concat(e.kids)
    out << plain unless e.kind == :tone && e.args == plain.args
    e.args.each_with_index do |a, i|
      if a.is_a?(Array) && a.first == :lfo
        args = e.args.dup
        args[i] = [:const, ((a[2] + a[3]) / 2.0).round(3)]
        out << Expr.new(e.kind, args, e.kids)
      elsif a.is_a?(Array) && %i[fm pwm].include?(a.first)
        args = e.args.dup
        args[i] = nil
        out << Expr.new(e.kind, args, e.kids)
      end
    end
    e.kids.each_with_index do |k, i|
      variants(k).each do |v|
        kids = e.kids.dup
        kids[i] = v
        out << Expr.new(e.kind, e.args, kids)
      end
    end
    out.uniq { |x| code(x) }
  end

  def shrink(expr, relation, limit: 200)
    tries = 0
    loop do
      smaller = variants(expr).sort_by { |v| code(v).length }.find do |v|
        break nil if (tries += 1) > limit
        next false if code(v).length >= code(expr).length

        r = begin
          build(code(v))
          check(relation, code(v))
        rescue StandardError
          nil # (a variant that doesn't build isn't the same failure)
        end
        r.is_a?(String)
      end
      return expr unless smaller

      expr = smaller
    end
  end

  # Generates the graph for +seed+, checks every relation, and returns the
  # Failures (shrunk) and a Hash of counts.
  # Examples of generated graphs that didn't build (generator bugs or
  # library errors; the spec prints them)
  def invalid_examples = @invalid_examples || []

  def run_seed(seed, relations: RELATIONS, counts: Hash.new(0))
    rng = Random.new(seed)
    expr = generate(rng)
    text = code(expr)
    begin
      with_plan(enabled: false) { build(text) }
    rescue StandardError => e
      counts[:invalid] += 1
      (@invalid_examples ||= []) << "#{text}: #{e.class}: #{e.message.lines.first}" if counts[:invalid] <= 5
      return []
    end
    counts[:graphs] += 1
    relations.filter_map do |rel|
      r = check(rel, text)
      if r.nil?
        counts[rel] += 1
        nil
      elsif r == :skip
        counts[:"#{rel}_skipped"] += 1
        nil
      else
        small = shrink(expr, rel)
        Failure.new(seed: seed, relation: rel, code: code(small), message: check(rel, code(small)), original: text)
      end
    end
  end
end
