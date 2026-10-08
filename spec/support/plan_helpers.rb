# Spec support for the plan layer (MB::Sound::Plan): deterministic boundary
# inputs and a helper that runs the same graph unplanned, planned in C, and
# planned with the Ruby mirror, block by block, and compares the samples.
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

  # A pseudo-random mix of block sizes from 1 to 800, with the edges
  # (1, 2, 127/128/129, 511/512, 800) included.
  SIZES = [1, 2, 3, 800, 127, 128, 129, 5, 511, 512, 64, 799, 17, 256, 1, 333, 700, 9, 128, 600, 41].freeze

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
  Result = Struct.new(:outputs, :installations, :graphs, keyword_init: true) do
    def regions(engine = :c)
      installations[engine]&.regions || []
    end

    def program(engine = :c)
      regions(engine).first&.program
    end
  end

  # Builds the graph with the block (called with a Copy, inside
  # MB::Sound.with_seed so random choices repeat) for each of :unfused, :c,
  # and :ruby; installs plans on the :c and :ruby copies; samples every copy
  # block by block over +sizes+; and expects the planned copies to give the
  # unfused samples exactly (or within +tolerance+, relative to 1;
  # +ruby_tolerance+ for the Ruby mirror, whose tone ops are the Tone's own
  # Ruby path, exact for most shapes but not complex sines).  Also
  # expects every planned block to have run planned unless +fallbacks+.
  # Returns a Result.
  def plan_compare(sizes: SIZES, tolerance: nil, ruby_tolerance: nil, engines: [:c, :ruby], fallbacks: false, check: nil, &build)
    copies = ([:unfused] + engines).to_h { |e| [e, Copy.new(e)] }
    graphs = copies.to_h { |e, ctx| [e, MB::Sound.with_seed(1234) { build.call(ctx) }] }

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

    unless fallbacks
      installations.each do |e, inst|
        inst.regions.each do |r|
          expect(r.unfused_blocks).to eq(0), "#{e}: #{r.unfused_blocks} blocks ran unfused (#{r.disabled})\n#{r}"
        end
      end
    end

    Result.new(outputs: outputs, installations: installations, graphs: graphs)
  end

  # The ops of a Result's first region, as op class names (e.g. [:Mul, :Tone]).
  def plan_op_names(result, engine = :c)
    result.program(engine).ops.map { |op| op.class.name.split('::').last.to_sym }
  end
end

RSpec.configure do |config|
  config.include PlanSpecHelpers
end
