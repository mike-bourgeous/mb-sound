module MB
  module Sound
    module Unison
      # Computes the frequencies of every unison copy (Pitch#unison) when the
      # detune is a graph node: one output (Hz) per copy, all from one read
      # of the base frequency and the detune per buffer, in one C call
      # (MB::Sound::FastUnison; exact Ruby mirror Detune::RubyKernel).
      #
      # Each copy has a fixed layout position, a fraction from -1 to 1 of the
      # detune (+fractions+; see Unison.fractions), so the detune node (in
      # semitones, the outermost copies' distance either side of the pitch)
      # scales the layout.  Two ways to get the frequencies (+mode:+):
      #
      # - :exact (default) - every copy at f × 2 ** (fraction × detune /
      #   12), every sample (one exp() per copy per sample).
      # - :interp - only the outermost ratio r = 2 ** (detune / 12)
      #   is computed exactly, at control points, and interpolated linearly
      #   in between; the copies are spaced linearly in Hz between f / r and
      #   f × r (copy at fraction a: f × (1/r + (r - 1/r) × (a + 1) / 2)).
      #   The outermost copies are exact at control points; inner copies are
      #   sharp by up to 1200 × log2(cosh(x)) cents with x = detune × ln 2 /
      #   12 (the middle one: 0.03 cents at 10 cents of detune, 0.18 at 25,
      #   0.72 at 50, 2.9 at 100).  Control points come every +control+
      #   samples of the stream (DEFAULT_CONTROL = 16), wherever buffers
      #   start, and each is ramped to over the +control+ samples after it
      #   (so the output doesn't depend on the buffer size, with 16 samples
      #   of latency); with +control+ nil the control point is the last
      #   sample of each buffer (no latency, but buffer-size dependent).
      #   About half the cost of :exact's detune math for 7 copies at
      #   512-sample buffers, but that is only ~0.15% of realtime of a
      #   whole 7-saw unison, so :exact became the default (2026-10-07).
      #
      # A detune buffer with every value the same (e.g. a constant node, or
      # a MIDI controller that isn't moving) uses one ratio per copy for the
      # whole buffer in :exact mode (no exp() per sample), and with a
      # constant base frequency (e.g. `110.hz`) an unchanged detune (in
      # :interp mode once the ramp to it has finished) keeps the previous
      # frame.
      class Detune
        include GraphNode
        include GraphNode::SampleRateHelper
        include GraphNode::MultiOutput

        # Ways to compute the copies' frequencies (see the class
        # description).
        MODES = [:interp, :exact].freeze

        # The samples between :interp control points by default (nil: one
        # per buffer; see the class description).
        DEFAULT_CONTROL = 16

        # ln(2) / 12: semitones to a natural log ratio.
        LOG_SEMITONE = Math.log(2) / 12

        # One output of a Detune node: a copy's frequency in Hz.
        class Output
          include GraphNode
          include GraphNode::NodeOutput

          # The copy's index.
          attr_reader :index

          def initialize(owner, index)
            @owner = owner
            @index = index
          end

          def sample(count)
            @owner.sample_output(count, @index)
          end

          def sample_rate
            @owner.sample_rate
          end

          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end

          # The copy's latest frequency (Hz).
          def value
            @owner.value(@index)
          end

          def sources
            { detune: @owner }
          end

          def to_s
            "Unison copy #{@index + 1} of #{@owner.outputs.length}"
          end
        end

        # The fixed layout positions (-1..1) of the copies.
        attr_reader :fractions

        # :interp or :exact (see the class description).
        attr_reader :mode

        # The samples between control points in :interp mode (nil for one
        # per buffer, at its last sample; see the class description).
        attr_reader :control

        # The frequency outputs, one per copy.
        attr_reader :outputs

        # Creates a Detune node for copies at +fractions+ of +detune+ (a node
        # of semitones) around +frequency+ (Hz, a number or node).  See the
        # class description for +mode+ and +control+.  +kernel+ is
        # MB::Sound::FastUnison (C) or Detune::RubyKernel (its exact mirror;
        # for specs and benchmarks).
        def initialize(frequency, detune, fractions:, mode: :exact, control: DEFAULT_CONTROL, sample_rate: 48000, kernel: MB::Sound::FastUnison)
          raise ArgumentError, "Unknown detune mode #{mode.inspect} (use #{MODES.map(&:inspect).join(' or ')})" unless MODES.include?(mode)
          raise ArgumentError, "The detune control interval must be a positive Integer or nil (got #{control.inspect})" unless control.nil? || (control.is_a?(Integer) && control > 0)
          raise ArgumentError, 'Detune fractions must be numbers in -1..1' unless fractions.all? { |a| a.is_a?(Numeric) && (-1..1).cover?(a) }

          @sample_rate = sample_rate.to_f
          @frequency = frequency.is_a?(Numeric) ? frequency.to_f : frequency.get_sampler
          @detune = detune.get_sampler
          @fractions = fractions.map(&:to_f).freeze
          @positions = @fractions.map { |a| (a + 1) * 0.5 }.freeze
          @mode = mode
          @control = control
          @kernel = kernel

          @outputs = Array.new(@fractions.length) { |i| Output.new(self, i) }.freeze
          @sampled = []
          @data = nil
          @views = nil

          # Exact ratios for a constant detune, and the inputs of an unchanged
          # frame (a constant base frequency and detune)
          @ratios_for = nil
          @ratios = nil
          @frame_key = nil

          # The :interp kernel's state ([previous ratio, current ratio, samples
          # since the control point]; nil before the first buffer)
          @state = nil

          @node_type_name = 'Unison Detune'
        end

        def sources
          { frequency: @frequency, detune: @detune }
        end

        # The latest frequency of copy +index+ (Hz).
        def value(index)
          return @data[index, -1] if @data

          # Before the first buffer: the base frequency
          @frequency.is_a?(Numeric) ? @frequency : @frequency.value
        end

        # Called by the outputs: computes a new frame of every copy's
        # frequency once each output has been read (or one is read again),
        # and returns copy +index+'s buffer (reused; overwritten by the next
        # frame).
        def sample_output(count, index)
          if @data.nil? || @sampled.include?(index)
            @sampled.clear
            return nil if compute(count).nil?
          end

          @sampled << index
          @views[index]
        end

        def to_s
          "Unison detune (#{@fractions.length} copies, #{@mode}#{@control ? ", control every #{@control}" : ''})"
        end

        private

        # Computes the next frame into @data.  Returns nil at the end.
        def compute(count)
          f = @frequency.is_a?(Numeric) ? @frequency : @frequency.sample(count)
          return @data = nil if f.nil?

          d = @detune.sample(count)
          return @data = nil if d.nil?

          n = d.length
          unless f.is_a?(Numeric)
            n = f.length if f.length < n
            f = f[0...n] if f.length > n
          end
          d = d[0...n] if d.length > n

          min, max = d.minmax
          constant = min == max
          # In :interp mode only once the ramp to it has finished
          constant = false if @mode == :interp && !(@state && @state[0] == @state[1] && @state[1] == Math.exp(min * LOG_SEMITONE))

          # A constant pitch and detune repeat the last frame (keeping the
          # control points on their grid)
          key = constant && f.is_a?(Numeric) ? [f, min] : nil
          if key && key == @frame_key && @data.shape[1] == n
            @state[2] = (@state[2].to_i + n) % @control if @state && @control
            return @data
          end

          @frame_key = key
          make_frame(n)

          if @mode == :exact
            if constant
              @kernel.scale(@data, f, exact_ratios(min))
            else
              @kernel.exact(@data, f, d, @fractions)
            end
          else
            unless @state
              r = Math.exp(d[0] * LOG_SEMITONE)
              @state = Numo::DFloat[r, r, 0]
            end
            @kernel.interp(@data, f, d, @positions, @state, @control || 0)
          end

          @data
        end

        # Every copy's exact ratio for a detune of +d+ semitones (the same
        # operations as the kernel's exact mode).
        def exact_ratios(d)
          return @ratios if @ratios_for == d

          x = d * LOG_SEMITONE
          @ratios_for = d
          @ratios = @fractions.map { |a| Math.exp(a * x) }
        end

        # Makes sure @data holds a count×n frame.
        def make_frame(n)
          return if @data && @data.shape[1] == n

          @data = Numo::SFloat.zeros(@fractions.length, n)
          @views = Array.new(@fractions.length) { |i| @data[i, true] }
          @frame_key = nil
        end

        public

        # The Ruby mirror of MB::Sound::FastUnison (see
        # ext/mb/sound/fast_unison/fast_unison.c): the same operations, so
        # specs can check that both give exactly the same samples.
        module RubyKernel
          # Copy i at f × exp(fraction_i × (d × K)).
          def self.exact(out, freq, detune, fractions)
            _count, n = check_out(out)
            x = (read(detune, n) * LOG_SEMITONE).reshape(1, n)
            frac = Numo::DFloat.cast(fractions).reshape(fractions.length, 1)
            out[] = freq_row(freq, n) * Numo::NMath.exp(frac * x)
            nil
          end

          # Copy i at f × ratio_i.
          def self.scale(out, freq, ratios)
            _count, n = check_out(out)
            out[] = freq_row(freq, n) * Numo::DFloat.cast(ratios).reshape(ratios.length, 1)
            nil
          end

          # The interpolated outermost ratio (see the class description and
          # the C kernel); updates +state+ ([r_prev, r_cur, phase]).
          def self.interp(out, freq, detune, positions, state, control)
            count, n = check_out(out)
            raise ArgumentError, 'The state must be a contiguous DFloat of 3 values' unless state.is_a?(Numo::DFloat) && state.shape == [3]
            raise ArgumentError, 'The control interval must not be negative' if control < 0

            d = read(detune, n)
            fr = freq_row(freq, n)
            u = Numo::DFloat.cast(positions).reshape(count, 1)
            r = Numo::DFloat.zeros(n)

            if control == 0
              return nil if n == 0

              r0 = state[0]
              r1 = Math.exp(d[-1] * LOG_SEMITONE)
              r[0..] = r0 + (r1 - r0) * (Numo::DFloat.new(n).seq(1) / n)
              state[0] = state[1] = r1
            else
              r_prev, r_cur, ph = state.to_a
              ph = ph.to_i
              raise ArgumentError, "The state's phase must be below the control interval" if ph >= control

              a = 0
              while a < n
                if ph == 0
                  r_prev = r_cur
                  r_cur = Math.exp(d[a] * LOG_SEMITONE)
                end
                len = [control - ph, n - a].min
                r[a...(a + len)] = r_prev + (r_cur - r_prev) * (Numo::DFloat.new(len).seq(ph + 1) / control)
                a += len
                ph += len
                ph = 0 if ph == control
              end

              state[0] = r_prev
              state[1] = r_cur
              state[2] = ph
            end

            ir = 1.0 / r
            lo = ir * fr
            span = (r - ir) * fr
            out[] = lo + u * span
            nil
          end

          def self.check_out(out)
            raise ArgumentError, 'The output must be a 2D SFloat NArray (copies x samples)' unless out.is_a?(Numo::SFloat) && out.ndim == 2
            out.shape
          end

          # A signal input as float32 values in a DFloat.
          def self.read(buf, n)
            raise ArgumentError, "Expected #{n} values" unless buf.length == n
            Numo::DFloat.cast(Numo::SFloat.cast(buf))
          end

          def self.freq_row(freq, n)
            freq.is_a?(Numeric) ? freq.to_f : read(freq, n).reshape(1, n)
          end
        end
      end
    end
  end
end
