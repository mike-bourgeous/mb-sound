module MB
  module Sound
    module GraphNode
      # A granular cloud of one Sample (see Sample#grains and
      # design/notes/granular.md): grains start on exact samples at
      # +density+ per second (Poisson-spaced at +jitter+ 1, regular at 0),
      # each a windowed read of +size+ seconds centered at +position+ (0..1
      # of the sample, plus a +scan+ playhead, plus ± +spread+), pitched by
      # +pitch+ semitones (or a random choice of an Array) ± +pitch_spread+,
      # panned ± +pan_spread+, backwards with chance +reverse+.  Every
      # parameter is a number or a node read per sample; a grain keeps the
      # values of its onset sample.  Reads use the sample's band-limited
      # levels (or its drop-sample read), so pitched-up grains don't alias.
      #
      # Stereo out: a MultiOutput node whose two outputs (#outputs) must be
      # sampled in turn every buffer.  Kernel FastSampler.grains (exact
      # Ruby mirror Granular::KernelRuby.grains); the same output at any
      # buffer size.  A plan boundary.  Never ends unless an input does.
      class Grains
        include MultiOutput
        include Nameable
        node_traits memory: :short

        # One output channel (0 left, 1 right).
        class Output
          include GraphNode
          include GraphNode::SampleRateHelper
          include GraphNode::NodeOutput
          node_traits memory: :none

          attr_reader :index

          def initialize(grains, index)
            @owner = grains
            @grains = grains
            @index = index
            @node_type_name = "Grains #{index == 0 ? 'L' : 'R'}"
          end

          def sample(count)
            @grains.sample_internal(count, @index)
          end

          def sample_rate
            @grains.sample_rate
          end

          def sample_rate=(rate)
            @grains.sample_rate = rate
            self
          end

          def sources
            { grains: @grains }
          end

          def plan_unsupported_reason
            'grains are a plan boundary for now'
          end

          def to_s
            "#{@grains} #{@index == 0 ? 'left' : 'right'}"
          end
        end

        # normalize: options and their kernel codes.
        NORMALIZE = { true => 1, power: 1, amplitude: 2, false => 0, nil => 0 }.freeze

        # The signal inputs in kernel order.
        INPUTS = %i[trigger density size position spread pitch pitch_spread pan_spread reverse freq scan jitter].freeze

        # The Sample played.
        attr_reader :sample

        # The random seed.
        attr_reader :seed

        # The most grains sounding at once.
        attr_reader :max_grains

        attr_reader :sample_rate

        # See Sample#grains for the options.
        def initialize(sample, density: 20, size: 0.1, position: nil, scan: nil, spread: 0, pitch: 0, pitch_spread: 0, pan_spread: 0.5,
                       reverse: 0, window: :hann, jitter: 1, normalize: true, max_grains: Granular::MAX_GRAINS, seed: nil,
                       interpolation: nil, mips: nil, freq: nil, trigger: nil, sample_rate: 48000)
          raise ArgumentError, "Grains play a Sample (got #{sample.inspect})" unless sample.is_a?(MB::Sound::Sample)
          raise ArgumentError, 'Grains need a sample of at least 2 samples' if sample.length < 2
          @sample = sample
          @sample_rate = sample_rate.to_f
          @max_grains = Integer(max_grains)
          unless @max_grains.between?(1, Granular::KernelRuby::MAX_SLOTS)
            raise ArgumentError, "max_grains: is 1 to #{Granular::KernelRuby::MAX_SLOTS} (got #{max_grains})"
          end

          scan = position.nil? ? 1 : 0 if scan.nil?
          position = 0 if position.nil?
          choices = []
          if pitch.is_a?(Array)
            choices = pitch.map { |p| Interval.semitones(p).to_f }
            raise ArgumentError, 'Give 1 to 64 pitch choices' if choices.empty? || choices.length > 64
            pitch = 0
          end
          @choices = choices.freeze

          @inputs = {
            trigger: trigger.nil? ? 0.0 : input(trigger, :trigger),
            density: input(density, :density),
            size: input(size, :size),
            position: input(position, :position),
            spread: input(spread, :position),
            pitch: input(pitch, :semitones),
            pitch_spread: input(pitch_spread, :semitones),
            pan_spread: input(pan_spread, :number),
            reverse: input(reverse == true ? 1 : (reverse == false ? 0 : reverse), :number),
            freq: freq.nil? ? nil : input(freq, :hz),
            scan: input(scan, :number),
            jitter: input(jitter, :number),
          }

          @window_shape = window
          @window = Granular.window(window)
          @normalize = NORMALIZE.fetch(normalize) { raise ArgumentError, "normalize: is true/:power, :amplitude, or false (got #{normalize.inspect})" }
          @mean_square = @normalize == 2 ? @window[0...-1].mean.to_f : Granular.mean_square(@window)
          @interpolation = (interpolation || sample.interpolation || :optimal).to_sym
          MB::Sound::Wavetable::INTERPOLATIONS.fetch(@interpolation) { raise ArgumentError, "Unknown interpolation #{interpolation.inspect}" }
          @mips = mips.nil? ? (sample.mips.nil? ? :default : sample.mips) : mips
          @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          @outputs = [Output.new(self, 0), Output.new(self, 1)].freeze
          @node_type_name = 'Grains'
          @sampled = []
          @bufs = nil
          @flip = 0
          build_tables
          reset
        end

        def outputs
          @outputs
        end

        # Silences every grain and restarts the random state and playhead.
        def reset
          @slots = Numo::DFloat.zeros(@max_grains, Granular::KernelRuby::COLS)
          @state = Numo::DFloat[1.0, 1.0, 0.0]
          @rng = Numo::UInt64[@seed & Tone::MASK64]
          self
        end

        def sample_rate=(rate)
          return self if rate.to_f == @sample_rate
          @sample_rate = rate.to_f
          @inputs.each_value { |v| v.sample_rate = rate if v.respond_to?(:sample_rate=) }
          build_tables
          self
        end

        # The number of grains sounding now.
        def active_grains
          (@slots[true, Granular::KernelRuby::ACTIVE].ne 0).count_true
        end

        # Computes both outputs once per buffer and returns output +index+.
        def sample_internal(count, index)
          if @sampled.include?(index) || @out.nil?
            # (one output read alone, e.g. `grains[0]`, is fine: the other
            # is simply not used)
            @sampled.clear
            @out = compute(count)
          end
          return nil if @out.nil?
          @sampled << index
          @out[index]
        end

        def sources
          @inputs.reject { |_, v| v.nil? || v.is_a?(Numeric) }
        end

        def plan_unsupported_reason
          'grains are a plan boundary for now'
        end

        def to_s
          "Grains of #{@sample}"
        end

        private

        def compute(count)
          values = INPUTS.map { |k|
            v = @inputs[k]
            next v if v.nil? || v.is_a?(Numeric)
            b = v.sample(count)
            return nil if b.nil? || b.empty?
            raise ArgumentError, 'Grain inputs must give the buffer size asked for' if b.length != count
            b
          }

          # Two sets of output buffers alternate, so the last buffer stays
          # valid while a Tee shares it
          @bufs = Array.new(2) { Array.new(2) { Numo::SFloat.zeros(count) } } if @bufs.nil? || @bufs[0][0].length != count
          @flip ^= 1
          l, r = @bufs[@flip]
          Kernels.grains(l, r, @specs, @slots, @state, @rng, @window, values, config)
          [l, r]
        end

        def config
          a4 = MB::Sound.tuning.frequency_of(69).to_f
          return @config if @config && @config_a4 == a4

          s = @sample
          @config_a4 = a4
          sinc = @interpolation == :sinc ? MB::Sound::Wavetable::SINC_KERNEL : nil
          @config = [
            @sample_rate, MB::Sound.tuning.frequency_of(s.root).to_f, @choices, MB::Sound::Wavetable::INTERPOLATIONS.fetch(@interpolation), sinc,
            @normalize, @mean_square, s.start.to_f, s.stop.to_f, s.reversed?, s.sample_rate / @sample_rate, s.tune, s.level,
            (Granular::MAX_SIZE * @sample_rate).round,
          ].freeze
        end

        def build_tables
          s = @sample
          @specs = Array.new([s.channel_count, 2].min) { |c| s.audio.table(c, @mips).kernel_spec(@sample_rate, @interpolation) }.freeze
          @config = nil
        end

        # +x+ as a kernel input: a number (converted from +kind+'s units) or
        # a node's sampler.
        def input(x, kind)
          case x
          when Numeric
            x.to_f
          when MB::Sound::Interval
            Interval.semitones(x).to_f
          when MB::Sound::Length
            case kind
            when :size then Length.seconds(x, sample_rate: @sample_rate)
            when :position then @sample.position(x).to_f / @sample.length
            when :density then 1.0 / Length.seconds(x, sample_rate: @sample_rate)
            else raise ArgumentError, "A length doesn't fit #{kind} (got #{x.inspect})"
            end
          when MB::Sound::Pitch
            f = x.oscillator_frequency
            f.is_a?(Numeric) ? f.to_f : f.get_sampler
          else
            raise ArgumentError, "Grain parameters are numbers or nodes (got #{x.inspect})" unless x.respond_to?(:sample)
            x.get_sampler
          end
        end
      end
    end
  end
end
