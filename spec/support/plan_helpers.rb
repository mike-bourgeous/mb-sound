# Spec support for the plan layer (MB::Sound::Plan): deterministic boundary
# inputs and a helper that runs the same graph unplanned, planned in C, and
# planned with the Ruby mirror, block by block, and compares the samples.
#
# Block sizes: the default suite runs 1, 7, 128, and 800 samples plus one
# random size seeded by RSpec's seed (QUICK_SIZES); MB_SOUND_PLAN_FULL=1
# (`rake plan:full`) runs the full 21-size sweep (FULL_SIZES) for branches
# that change the plan layer itself.
module PlanSpecHelpers
  # A graph node a plan reads as a boundary input (it has no ops): a
  # deterministic signal of the absolute sample index, so it gives the same
  # samples whatever the block sizes.  +kind+:
  # - :wave: a sum of slow sines, about -1..1 (scaled by +scale+, moved by
  #   +offset+)
  # - :impulses: +value+ at the sample indices in +at+, else 0 (triggers)
  # - :steps: piecewise constant, a new value every +every+ samples
  # With +complex: true+ the buffers are SComplex (imaginary part from
  # another wave); +ends_at:+ makes it return a short buffer, then nil.
  class Source
    include MB::Sound::GraphNode
    include MB::Sound::GraphNode::SampleRateHelper

    attr_reader :position

    # The last sample index this source needs a comparison to reach for its
    # events to happen (impulses, the end), or nil.
    attr_reader :last_event

    def initialize(kind: :wave, seed: 1, scale: 1.0, offset: 0.0, at: [], value: 1.0, every: 100, complex: false, ends_at: nil, sample_rate: 48000)
      @kind = kind
      @seed = seed
      @scale = scale
      @offset = offset
      @at = at
      @value = value
      @every = every
      @complex = complex
      @ends_at = ends_at
      @sample_rate = sample_rate.to_f
      @position = 0

      @last_event = [(at.max if kind == :impulses), ends_at].compact.max
      Thread.current[:plan_spec_sources]&.push(self)
    end

    def sources
      {}
    end

    # The type a plan expects (see MB::Sound::Plan.output_type).
    def plan_output_type
      @complex ? :complex : :real
    end

    def sample(count)
      if @ends_at
        left = @ends_at - @position
        return nil if left <= 0
        count = left if count > left
      end

      idx = Numo::DFloat.new(count).seq(@position)
      values =
        case @kind
        when :wave
          (Numo::NMath.sin(idx * (0.0123 * @seed)) * 0.6 + Numo::NMath.sin(idx * (0.00071 * (@seed + 2)) + @seed) * 0.4) * @scale + @offset
        when :impulses
          v = Numo::DFloat.zeros(count)
          @at.each { |i| v[i - @position] = @value if i >= @position && i < @position + count }
          v
        when :steps
          Numo::NMath.sin((idx / @every).floor * (1.7 * @seed)) * @scale + @offset
        else
          raise ArgumentError, "Unknown kind #{@kind}"
        end

      @position += count
      if @complex
        im = Numo::NMath.cos(idx * (0.0091 * @seed)) * @scale
        Numo::SComplex.cast(values + im * 1i)
      else
        Numo::SFloat.cast(values)
      end
    end
  end

  # The relative tolerance for programs with inexact ops (see
  # #plan_compare): -100 dB.
  INEXACT_TOLERANCE = 1e-5

  # True with MB_SOUND_PLAN_FULL=1 (`rake plan:full`): the full block-size
  # sweep.
  FULL = %w[1 true yes].include?(ENV['MB_SOUND_PLAN_FULL'].to_s.downcase)

  # A pseudo-random mix of block sizes from 1 to 800, with the edges
  # (1, 2, 127/128/129, 511/512, 800) included (5166 samples).
  FULL_SIZES = [1, 2, 3, 800, 127, 128, 129, 5, 511, 512, 64, 799, 17, 256, 1, 333, 700, 9, 128, 600, 41].freeze

  # One random block size from 2 to 799 (not 7 or 128), from RSpec's seed,
  # so `rspec --seed N` repeats it.
  RANDOM_SIZE = ((2..799).to_a - [7, 128]).sample(random: Random.new(RSpec.configuration.seed.to_i))

  # The default suite's block sizes (user decision 2026-10-10): one sample,
  # an odd small size, 128, 800, and RANDOM_SIZE.
  QUICK_SIZES = [1, 7, 128, 800, RANDOM_SIZE].freeze

  # The block sizes plan specs use (QUICK_SIZES, or FULL_SIZES with
  # MB_SOUND_PLAN_FULL=1).
  SIZES = FULL ? FULL_SIZES : QUICK_SIZES

  # SIZES repeated until they cover at least +samples+ samples and +blocks+
  # blocks.
  def self.sizes_for(samples: 0, blocks: 0)
    list = []
    list << SIZES[list.length % SIZES.length] while list.sum < samples || list.length < blocks
    list.freeze
  end

  # Per-copy context for #plan_compare's build block: register actions to
  # run before given blocks (parameter changes, structural changes).
  class Copy
    attr_reader :engine, :events

    def initialize(engine)
      @engine = engine
      @events = Hash.new { |h, k| h[k] = [] }
    end

    # Runs the block before block number +index+ (0-based).
    def before_block(index, &block)
      @events[index] << block
    end
  end

  # The result of #plan_compare.
  Result = Struct.new(:outputs, :installations, :graphs, :sizes, keyword_init: true) do
    def regions(engine = :c)
      installations[engine]&.regions || []
    end

    def program(engine = :c)
      regions(engine).first&.program
    end

    # Blocks that ran unfused in every region the installation had,
    # including regions replaced by rebuilds (see
    # Plan::Installation#unfused_blocks).
    def unfused_blocks(engine = :c)
      installations[engine].unfused_blocks
    end
  end

  # Builds the graph with the block (called with a Copy, inside
  # MB::Sound.with_seed so random choices repeat) for each of :unfused, :c,
  # and :ruby; installs plans on the :c and :ruby copies; samples every copy
  # block by block over +sizes+; and expects the planned copies to give the
  # unfused samples exactly (or within +tolerance+, relative to 1;
  # +ruby_tolerance+ for the Ruby mirror, whose tone ops are the Tone's own
  # Ruby path, exact for most shapes but not complex sines).  Also
  # expects every planned block to have run planned unless +fallbacks+
  # (true allows any unfused blocks, an Integer at most that many per region).
  # Returns a Result.
  #
  # The default +sizes+ (SIZES) are repeated as needed to reach every
  # Copy#before_block index and every Source's last event (impulse or end),
  # followed by another pass over SIZES (so what happens after an event,
  # e.g. a rebuild once an input ended, is compared too), and cover at least
  # one pass; explicit +sizes+ that miss an event raise, so no event is
  # silently left out.  Result#sizes has the sizes used.
  def plan_compare(sizes: nil, tolerance: nil, ruby_tolerance: nil, engines: [:c, :ruby], fallbacks: false, check: nil, &build)
    copies = ([:unfused] + engines).to_h { |e| [e, Copy.new(e)] }
    sources = []
    graphs = copies.to_h do |e, ctx|
      Thread.current[:plan_spec_sources] = sources
      [e, MB::Sound.with_seed(1234) { build.call(ctx) }]
    ensure
      Thread.current[:plan_spec_sources] = nil
    end

    last_block = copies.values.flat_map { |ctx| ctx.events.select { |_, list| list.any? }.keys }.max || -1
    last_sample = sources.filter_map(&:last_event).max || -1
    if sizes
      if last_block >= sizes.length || last_sample >= sizes.sum
        raise ArgumentError, "plan_compare sizes #{sizes.length} blocks / #{sizes.sum} samples miss an event (block #{last_block}, sample #{last_sample})"
      end
    else
      reach = PlanSpecHelpers.sizes_for(samples: last_sample + 1, blocks: last_block + 1)
      sizes = PlanSpecHelpers.sizes_for(blocks: reach.length + SIZES.length)
    end

    installations = {}
    engines.each do |e|
      inst = MB::Sound::Plan.install(graphs[e], engine: e, check: check)
      expect(inst).not_to be_nil, "expected a plan for #{graphs[e]}"
      installations[e] = inst
    end

    outputs = Hash.new { |h, k| h[k] = [] }
    sizes.each_with_index do |n, i|
      copies.each do |e, ctx|
        ctx.events[i].each { |ev| ev.call }
        out = graphs[e].sample(n)
        outputs[e] << out&.dup
      end

      ref = outputs[:unfused].last
      engines.each do |e|
        got = outputs[e].last
        if ref.nil?
          expect(got).to be_nil, "block #{i} (#{n} samples, #{e}): expected nil (the unfused graph ended), got #{got.class}"
          next
        end

        expect(got).not_to be_nil, "block #{i} (#{n} samples, #{e}): got nil, expected #{ref.length} samples"
        expect(got.class).to eq(ref.class), "block #{i} (#{n} samples, #{e}): got #{got.class}, expected #{ref.class}"
        expect(got.length).to eq(ref.length), "block #{i} (#{n} samples, #{e}): got #{got.length} samples, expected #{ref.length}"

        tol = e == :ruby ? (ruby_tolerance || tolerance) : tolerance
        # Programs with inexact ops (Plan.precision :fast's sines) are within
        # -100 dB of the peak (errors of fast modulators accumulate in the
        # phases they modulate over the whole comparison)
        unless installations[e].regions.all? { |r| r.program.nil? || r.program.exact? }
          tol = [tol || 0, INEXACT_TOLERANCE * [1.0, Numo::DComplex.cast(ref).abs.max].max].max
        end
        if tol
          diff = (Numo::DComplex.cast(got) - Numo::DComplex.cast(ref)).abs.max
          expect(diff).to be <= tol, "block #{i} (#{n} samples, #{e}): differs by #{diff}\n#{installations[e].regions.map(&:to_s).join("\n")}"
        else
          same = got.to_binary == ref.to_binary
          unless same
            d = (Numo::DComplex.cast(got) - Numo::DComplex.cast(ref)).abs
            idx = d.max_index
            raise RSpec::Expectations::ExpectationNotMetError, "block #{i} (#{n} samples, #{e}): not bit-exact; max diff #{d.max} at #{idx} (planned #{got[idx]}, unfused #{ref[idx]})\n#{installations[e].regions.map(&:to_s).join("\n")}"
          end
        end
      end
    end

    unless fallbacks == true
      installations.each do |e, inst|
        inst.regions.each do |r|
          expect(r.unfused_blocks).to be <= (fallbacks || 0), "#{e}: #{r.unfused_blocks} blocks ran unfused (#{r.disabled})\n#{r}"
        end
        # Regions a rebuild replaced without a successor on the same root
        dropped = inst.dropped_blocks[1]
        expect(dropped).to be <= (fallbacks || 0), "#{e}: #{dropped} blocks ran unfused in regions a rebuild dropped"
      end
    end

    Result.new(outputs: outputs, installations: installations, graphs: graphs, sizes: sizes)
  end

  # The ops of a Result's first region, as op class names (e.g. [:Mul, :Tone]).
  def plan_op_names(result, engine = :c)
    result.program(engine).ops.map { |op| op.class.name.split('::').last.to_sym }
  end
end

RSpec.configure do |config|
  config.include PlanSpecHelpers
end
