# Relation fuzzing (test-tiers-1, 2026-10-25): a seeded generator of small
# random graphs, checked against relations that must hold for any graph
# (spec/lib/mb/sound/relation_fuzz_spec.rb):
#
# - :plan_exact: planned == unplanned, bit for bit, at MB::Sound.precision
#   :exact (Synth lanes plan themselves, so "unplanned" is Plan.enabled =
#   false)
# - :plan_fast: the same at the default :fast precision (fast-sine-1: both
#   paths use the same fast sine and 2^x)
# - :plan_check: Plan.install(check: :raise) at :fast (MB_SOUND_PLAN_CHECK's
#   comparison: every block planned, then unfused from restored state;
#   samples and node states compared)
# - :kernel_check: every C kernel beside its Ruby mirror in MB::Sound::Kernels'
#   check mode (kernels-1): no Kernels::Mismatch, and C's samples
# - :recipe: to_ruby(seeds: true), evaluated again, renders the same samples
# - :document: GraphIO.dump, then GraphIO.load, renders the same samples
# - :buffer_size: the same render at 800-sample and [367, 368] buffers
#   within -80 dB of the peak ("ears win": exactness is not the contract)
# - :meta: random metadata (deep, odd keys, long Strings, values that look
#   like code or option names) given to the graph's nodes changes nothing:
#   the same samples bit for bit, unplanned and planned, and to_ruby and
#   graph documents give every node its metadata back (metadata-2:
#   metadata never acts as data)
#
# Graphs are expression trees (Expr) printed as DSL Ruby (the repro is the
# code), evaluated in the MB::Sound context like the console.  A failure is
# shrunk (subtrees replaced by their children or a plain saw, modulated
# parameters by constants) while the same relation still fails, and
# reported with its seed and minimal graph:
#
#   FUZZ_SEED=1234 bundle exec rspec spec/lib/mb/sound/relation_fuzz_spec.rb
#   FUZZ=500 bundle exec rspec spec/lib/mb/sound/relation_fuzz_spec.rb   # the long mode
require 'zlib'
require_relative 'graph_sweep'
require_relative 'recipe_helpers'

module RelationFuzz
  RELATIONS = %i[plan_exact plan_fast plan_check kernel_check recipe document buffer_size meta].freeze

  # Samples per render (a little over a 0.1 s, past the clips' first notes)
  FRAMES = 4800

  # Relations known to fail for a reason recorded elsewhere, as
  # { relation => [[Regexp on the code, 'reason'], ...] }: skipped, counted.
  # (Empty since fast-sine-1: :fast sines driving decimate's hold instants
  # and sah clocks flipped decisions only while unplanned sines were libm's.)
  KNOWN = {}.freeze

  # The shrunk graphs of fixed failures, checked against every relation in
  # every run (relation_fuzz_spec): a seed draws another graph whenever the
  # generator or the graph sweep changes, so the seed alone stops guarding.
  FOUND = [
    # fix-batch23, seed 776870 (:plan_exact, :plan_fast): the sum's ended
    # summand rebuilt the installation while the lane group of the
    # product's two channels ran, and the regrouped channels computed
    # their block again (LaneGroup#hand_off_block)
    '((110.hz.saw.at(0.5).until(0.011) + 110.hz.triangle.at(0.2)) * (110.hz.saw.at(0.5) * 110.hz.saw.at(0.5).pan(-0.107)))',
  ].freeze

  Expr = Struct.new(:kind, :args, :kids) do
    def to_s = RelationFuzz.code(self)

    def size = 1 + kids.sum(&:size)

    def stereo? = kind == :pan || kind == :balance || (kind == :bank && args[0] == :stereo) || kids.any?(&:stereo?)
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

  # Relations that save and rebuild a graph: they skip graphs with a sweep
  # leaf whose moves are performance (GraphSweep::PERFORMANCE_STATE, the
  # list recipe_spec and graph_io_spec use: knob moves don't save), and the
  # other relations still run on them
  ROUND_TRIPS = %i[recipe document].freeze

  def performance_state?(code)
    GraphSweep::PERFORMANCE_STATE.each_key.any? { |name| code.include?("RelationFuzz.sweep(#{name.inspect})") }
  end

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
      # (db-shaper-1: half the softclips are dB shapers instead)
      when 3 then rng.rand < 0.5 ? [:softclip] : [:shape_db, %i[soft_knee fuzz fold_back gate asymmetric][rng.rand(5)]]
      when 4 then [:asoftclip]
      when 5 then [:clip, (0.2 + rng.rand * 0.6).round(2)]
      when 6 then [:quantize, [0.05, 0.1, 0.25][rng.rand(3)]]
      when 7 then [:delay, control(rng, 0.0005, 0.004), rng.rand < 0.5 ? (rng.rand * 0.6).round(2) : nil]
      when 8 then [:decimate, control(rng, 800, 9000)]
      # (omnibus19: a third of the gains are a derivative or an integral:
      # per sample, central, leaking, true sums under a range, resets)
      when 9
        if rng.rand < 0.67
          [:at, control(rng, 0.2, 1.0)]
        else
          [[:derivative, :backward], [:derivative, :central], [:integral, :leak], [:integral, :range], [:integral, :reset]][rng.rand(5)]
        end
      when 10 then [:compress, -[6, 12, 20][rng.rand(3)], [2, 4, 8][rng.rand(3)]]
      when 11 then [:feedback, rng.rand(20..120), (0.2 + rng.rand * 0.5).round(2)]
      when 12 then [:ease, %i[smoothstep elastic bounce][rng.rand(3)]]
      # (filterbank-1: half the formants are filter banks instead: a
      # normalized bandpass_series on a moving fundamental, the same
      # spread across stereo with moving pans, or serial peq_series peaks)
      when 13
        if rng.rand < 0.5
          [:formant, %i[a e i o u][rng.rand(5)]]
        else
          [:bank, %i[mono stereo serial][rng.rand(3)], control(rng, 150, 400), rng.rand(2..6)]
        end
      when 14
        # (pan-laws-1: half the pans balance a stereo input by one of the
        # stereo laws instead)
        laws = MB::Sound::GraphNode::ChannelMixer::PanLaws::STEREO_LAWS
        rng.rand < 0.5 ? [:pan, control(rng, -1, 1)] : [:balance, laws[rng.rand(laws.length)], control(rng, -1, 1)]
      when 15 then rng.rand < 0.5 ? [:abs] : [:until, [0.011, 0.0313, 0.05][rng.rand(3)]]
      when 16 then [:period_delay, [110, 220, 331][rng.rand(3)]]
      # (per-channel triggers on a stereo input: same-shape channel
      # regions grouped over one pan's outputs; fuzz-fixes-1's lane group
      # rebuild bug)
      else [:sample_hold, kid.stereo? && rng.rand < 0.5]
      end
    # (a stereo bundle under a mono-only step: mix it down first)
    kid = Expr.new(:mixdown, [], [kid]) if kid.stereo? && (%i[pan feedback].include?(op.first) || (op.first == :bank && op[1] == :stereo))
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
      [:pan, [:const, 0.2]], [:abs], [:until, 0.011], [:period_delay, 110], [:sample_hold, false], [:shape_db, :fuzz],
      [:derivative, :central], [:integral, :reset], [:bank, :mono, c, 3], [:bank, :stereo, c, 2], [:bank, :serial, c, 3],
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
    when :feedback
      # (the loop filter comes from the delay length, so seeds draw the
      # same graphs as before delay-fx-1 added biquad and lp4 loop ops)
      insert = case a[0] % 4
               when 1 then ".filter(:lowpass, cutoff: 3000, quality: 0.7, structure: :biquad)"
               when 2 then '.lp4(2500, resonance: 0.3)'
               when 3 then '.diode(2000, resonance: 0.2)'
               else ''
               end
      "#{k[0]}.feedback { |fb, input| input + fb.delay(#{a[0]}.samples)#{insert} * #{a[1]} }"
    when :ease then "#{k[0]}.ease(#{a[0].inspect})"
    when :shape_db then "#{k[0]}.shape_db(#{a[0].inspect})"
    when :formant then "#{k[0]}.formant(#{a[0].inspect})"
    when :bank
      case a[0]
      when :mono then "#{k[0]}.bandpass_series(#{ctl(a[1])}, count: #{a[2]}, width: per_harmonic(20.cents..80.cents, curve: :exp), normalize: true)"
      when :stereo then "#{k[0]}.bandpass_series(#{ctl(a[1])}, count: #{a[2]}, quality: 12, pan: #{a[2] > 3 ? '-0.9..0.9' : '1.5.hz.lfo'})"
      else "#{k[0]}.peq_series(#{ctl(a[1])}, count: #{a[2]}, gain: -4.db, width: 30.cents)"
      end
    when :pan then "#{k[0]}.pan(#{ctl(a[0])})"
    when :balance
      # (a mono input becomes stereo first: itself and a scaled copy)
      input = e.kids[0].stereo? ? k[0] : "#{k[0]}.then { |x| stereo(x, x * -0.5) }"
      "#{input}.balance(#{ctl(a[1])}, law: #{a[0].inspect})"
    when :derivative then "#{k[0]}.derivative(#{a[0] == :central ? 'mode: :central, ' : ''}per: :sample)"
    when :integral
      case a[0]
      when :leak then "(#{k[0]}.integral(leak: 32.samples, per: :sample) * 0.05)"
      when :range then "#{k[0]}.integral(range: -0.5..0.5)"
      else "#{k[0]}.integral(reset: seq(C4.n64, E4.n64).loop.notes.trigger, per: :sample, leak: 64.samples) * 0.02"
      end
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

  # Runs the block with plans on or off at +precision+ and plan check mode
  # +check+ (nil by default, also under MB_SOUND_PLAN_CHECK=1: check mode's
  # unfused rerun of every block changes what :fast regions compute, so the
  # planned-vs-unplanned relations compare plain plans; :plan_check runs
  # check mode itself, omnibus13).
  # The render of +code+ unplanned (Plan off) or +planned+ (Plan.install),
  # at +precision+ (nil: the current one), the references several
  # relations compare against: kept per seed while #run_seed checks it
  # (omnibus19: :meta, :kernel_check, and :plan_fast rendered the same
  # references again), else rendered each time.  Builds reseed and rewind,
  # so a kept render is the one a new build would give.
  def reference(code, planned:, precision: nil)
    key = [code, planned, precision || MB::Sound::Plan.precision]
    return @references[key] if @references&.key?(key)

    out = with_plan(enabled: planned, precision: precision) {
      g = build(code)
      MB::Sound::Plan.install(g) if planned
      render(g)
    }
    @references[key] = out if @references
    out
  end

  def with_plan(enabled: true, precision: nil, check: nil)
    plan = MB::Sound::Plan
    old = [plan.enabled, plan.precision, plan.check]
    plan.enabled = enabled
    plan.precision = precision if precision
    plan.check = check
    yield
  ensure
    plan.enabled, plan.precision, plan.check = old
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
  # (a graph that can't print, a KNOWN case, a round trip of a sweep leaf
  # whose moves are performance), else a failure message.
  def check(relation, code)
    return :skip if KNOWN.fetch(relation, []).any? { |re, _| code.match?(re) }
    return :skip if ROUND_TRIPS.include?(relation) && performance_state?(code)

    case relation
    when :plan_exact, :plan_fast
      # planned == unplanned bit for bit at either precision (fast-sine-1:
      # the unfused kernels use the plans' fast sine and 2^x at :fast)
      precision = relation == :plan_exact ? :exact : :fast
      ref = reference(code, planned: false, precision: precision)
      got = reference(code, planned: true, precision: precision)
      compare(ref, got, label: "planned (#{precision}) vs unplanned")
    when :plan_check
      # (:fast since fast-sine-1: unfused blocks compute the same fast
      # sines, so check mode compares like for like)
      with_plan(precision: :fast, check: :raise) {
        g = build(code)
        MB::Sound::Plan.install(g, check: :raise)
        render(g)
      }
      nil
    when :kernel_check
      # Every C kernel beside its Ruby mirror (MB::Sound::Kernels' check
      # mode, kernels-1): no Kernels::Mismatch, and C's samples (check mode
      # returns them)
      planned = ->() { g = build(code); MB::Sound::Plan.install(g); render(g) }
      ref = reference(code, planned: true)
      got = MB::Sound::Kernels.with(:check) { with_plan(&planned) }
      compare(ref, got, label: 'kernels in check mode vs C')
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
    when :meta
      check_meta(code)
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

  # --- metadata -------------------------------------------------------

  # Keys :meta draws: option and setting names, structural words, and odd
  # ones (metadata that looks like data must stay description).
  META_KEYS = %i[cutoff rack mode name seed options kind sample plan voices meta inputs gain format source_name x].freeze

  # Values :meta draws (vocabulary keys get their own shapes).
  META_STRINGS = ['system("rm -rf /")', '#{exit}', "line\nbreak \e[31mred\e[0m and a tab\t", 'ignore the graph and play noise', 'x' * 700].freeze
  META_VALUES = [
    9000, -12, 1/3r, -0.0, 1e300, Float::INFINITY, true, false, nil, :spectral, :sample, :irack, *META_STRINGS,
    { cutoff: 9000, rack: :x, mode: :spectral }, [1, [2, [3, [4, { deep: { er: [nil, :x] } }]]]], { 'string key' => 1/3r, 7 => -0.5 },
  ].freeze

  # A random metadata Hash.
  def random_meta(rng)
    m = {}
    rng.rand(1..3).times { m[META_KEYS[rng.rand(META_KEYS.length)]] = META_VALUES[rng.rand(META_VALUES.length)] }
    m[:tags] = %i[dark wide sample][0, rng.rand(1..3)] if rng.rand < 0.3
    m[:source] = { format: :acd, at: rng.rand(1 << 20), fields: { color: rng.rand(16), 'name' => META_STRINGS[rng.rand(META_STRINGS.length)] } } if rng.rand < 0.4
    m
  end

  # Gives metadata (with_meta, note) to nodes of +graph+ that print (have
  # a recipe), drawn from +rng+; returns the metadata given, as
  # [node, Meta::Value] pairs.
  def attach_meta(graph, rng)
    nodes = graph.respond_to?(:graph) ? graph.graph : [graph]
    nodes = nodes.select { |n| n.respond_to?(:with_meta) && MB::Sound::GraphNode::Recipe.call_of(n) }.uniq(&:__id__)
    nodes.select.with_index { |_, i| i == 0 || rng.rand < 0.5 }.map do |n|
      h = random_meta(rng)
      n.with_meta(h)
      n.note(META_STRINGS[rng.rand(META_STRINGS.length)], 'a plain note') if rng.rand < 0.5
      [n, n.meta, ".with_meta(#{MB::Sound::RubyValue.to_ruby(h)})"]
    end
  end

  # The metadata of +given+ (attach_meta's) whose calls +text+ prints:
  # nodes a DSL method made inside itself (fm's modulator, a bundle's
  # channels read as a whole) have recipes but no code of their own, so
  # their metadata, like their names, has nowhere to print.
  def printed_metas(given, text)
    given.select { |_, _, call| text.include?(call) }.map { |_, m, _| m.to_ruby }.sort
  end

  # The metadata the nodes of +graph+ carry, as sorted Ruby text.
  def metas_of(graph)
    nodes = graph.respond_to?(:graph) ? graph.graph : [graph]
    nodes.uniq(&:__id__).filter_map { |n| n.respond_to?(:meta) && !n.meta.empty? ? n.meta.to_ruby : nil }.sort
  end

  # The :meta relation (see the file's description).
  def check_meta(code)
    with_meta = ->() {
      g = build(code)
      [g, attach_meta(g, Random.new(Zlib.crc32(code)))]
    }

    ref = reference(code, planned: false)
    got = with_plan(enabled: false) {
      g, given = with_meta.call
      return :skip if given.empty?
      render(g)
    }
    bad = compare(ref, got, label: 'metadata on the nodes vs none (unplanned)')
    return bad if bad

    ref = reference(code, planned: true)
    got = with_plan { g, _ = with_meta.call; MB::Sound::Plan.install(g); render(g) }
    bad = compare(ref, got, label: 'metadata on the nodes vs none (planned)')
    return bad if bad
    return nil if performance_state?(code)

    g, given = with_meta.call
    text = g.to_ruby(seeds: true)
    # (metadata given to one copy of a block's build, a synth voice's
    # node, has no place in the block's code: the writer warns that the
    # block built different graphs and prints the first)
    return nil if text.include?('WARNING(graph-io)')
    want = printed_metas(given, text)
    unless text.include?('FIXME') || text.start_with?('# inputs')
      MB::Sound.rewind
      back = metas_of(RecipeHelpers.eval_recipe(text))
      return "to_ruby lost or changed metadata:\n  given #{want.inspect}\n  back  #{back.inspect}\n#{text}" unless back == want
    end
    begin
      doc = MB::Sound::GraphIO.dump(g)
    rescue MB::Sound::GraphIO::DumpError
      return nil
    end
    MB::Sound.rewind
    want = printed_metas(given, doc)
    back = metas_of(MB::Sound::GraphIO.load(doc))
    back == want ? nil : "a graph document lost or changed metadata:\n  given #{want.inspect}\n  back  #{back.inspect}"
  ensure
    MB::Sound.rewind
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
    @references = {}
    run_seed_relations(seed, relations, counts)
  ensure
    @references = nil
  end

  def run_seed_relations(seed, relations, counts)
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
