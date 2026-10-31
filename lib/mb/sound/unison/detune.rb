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
      #
      # Plan layer (fix-alloc-1, 2026-10-31): in :exact mode the node is a
      # Plan::MultiDescribable, computing every copy's frequency in a
      # region of its own (one Plan::Op::UnisonCopy per copy, bit for bit
      # the kernels' samples), so a synth voice's unison runs fused, as it
      # did through per-copy Notes::Frequency nodes before gen-midi-2 gave
      # fixed detunes this node (its lanes group again instead of running
      # alone, about 50 objects per 128-frame buffer fewer in
      # render_allocations_spec's unison graph).  :interp mode (a ramp
      # state per control point) stays unfused.
      class Detune
        include GraphNode
        include GraphNode::SampleRateHelper
        include GraphNode::MultiOutput
        # (its moving ratios' state: #plan_snapshot)
        node_traits memory: :short, carry: :snapshot

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
          node_traits memory: :none

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

          # The Detune node, which the plan layer computes in a region of
          # its own (see MB::Sound::Plan::MultiDescribable): this output is
          # planned while it is.
          def plan_owner
            @owner
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
        # class description for +mode+ and +control+.  The kernels are
        # MB::Sound::FastUnison's (C) or Detune::RubyKernel's (their exact
        # mirrors), as MB::Sound::Kernels chooses.
        def initialize(frequency, detune, fractions:, mode: :exact, control: DEFAULT_CONTROL, sample_rate: 48000)
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

          @outputs = Array.new(@fractions.length) { |i| Output.new(self, i) }.freeze
          @sampled = []
          @data = nil
          @views = nil

          # Exact ratios for a constant detune
          @ratios_for = nil
          @ratios = nil

          # The :interp kernel's state ([previous ratio, current ratio, samples
          # since the control point]; nil before the first buffer)
          @state = nil

          # The last frame (an Array of one buffer per copy: views of
          # @data, or a plan region's outputs), and the unfused frames'
          # reused state: the detune range, the steady detune buffer seen
          # last (GraphNode::FrozenView::Key) and whether it was constant,
          # the frame's sample count, the other frame size's data, views,
          # and count (buffers split at events alternate a full and a
          # shorter size), and the base frequency and detune of a frame a
          # constant pitch and detune repeat
          @frame = nil
          @range = [nil, nil]
          @steady_key = GraphNode::FrozenView::Key.new
          @steady_constant = false
          @frame_n = nil
          @spare_data = nil
          @spare_views = nil
          @spare_n = nil
          @frame_f = nil
          @frame_d = nil

          # Set by the plan layer (see MB::Sound::Plan::MultiDescribable),
          # nil here so instances keep one object shape
          @plan_bypass = nil
          @plan_installations = nil
          @plan_member = nil
          @plan_region = nil
          @plan_observed = nil
          @plan_handoff = nil
          @plan_restart = nil
          @plan_excluded = nil

          @node_type_name = 'Unison Detune'
        end

        def sources
          { frequency: @frequency, detune: @detune }
        end

        # The latest frequency of copy +index+ (Hz).
        def value(index)
          return @frame[index][-1] if @frame

          # Before the first buffer: the base frequency
          @frequency.is_a?(Numeric) ? @frequency : @frequency.value
        end

        # Called by the outputs: computes a new frame of every copy's
        # frequency once each output has been read (or one is read again),
        # and returns copy +index+'s buffer (reused; overwritten by the next
        # frame).
        def sample_output(count, index)
          if @frame.nil? || @sampled.include?(index)
            @sampled.clear
            return nil if (@frame = plan_frame(count)).nil?
          end

          @sampled << index
          @frame[index]
        end

        # Plan layer (see the class description and
        # Plan::MultiDescribable): one Op::UnisonCopy per copy, reading the
        # base frequency (a Const for a number, used as a double as the
        # kernels do) and the detune.
        include Plan::MultiDescribable

        def plan_unsupported_reason
          return 'detune_mode: :interp (ramps between control points)' if @mode == :interp

          nil
        end

        def plan_describe(p)
          f = p[@frequency]
          d = p[@detune]
          @fractions.map { |a| p.unison_copy(d, f, a) }
        end

        # One frame of every copy's frequency (an Array of buffers, or nil
        # once an input ended): from the plan region rooted here while it
        # plans, else from this node's own kernels (#compute).
        def plan_frame(count)
          unless @plan_bypass
            # A frame a lane group computed for this node's replaced region
            # (see Plan::LaneGroup#hand_off)
            if (handoff = @plan_handoff)
              @plan_handoff = nil
              buf = handoff[0].take_handoff(handoff[1], count)
              return handoff[1].planned_frame(buf) unless buf.equal?(Plan::LaneGroup::NO_HANDOFF)
            end

            region = @plan_region
            return region.sample_outputs(count) if region && !region.unfused
          end

          compute(count)
        end

        def to_s
          "Unison detune (#{@fractions.length} copies, #{@mode}#{@control ? ", control every #{@control}" : ''})"
        end

        # For Session::Carry (a rebuilt graph continues this one): the
        # :interp kernel's ramp state (nil in :exact mode, whose frames
        # depend only on the inputs).
        def plan_snapshot
          [@state&.to_a]
        end

        # Restores #plan_snapshot.
        def plan_restore(snapshot)
          state, = snapshot
          @state = state && Numo::DFloat.cast(state)
          @frame_f = nil
        end

        private

        # Computes the next frame into @data, returning its views (one per
        # copy), or nil at the end.
        def compute(count)
          f = @frequency.is_a?(Numeric) ? @frequency : @frequency.sample(count)
          return ended if f.nil?

          d = @detune.sample(count)
          return ended if d.nil?

          n = d.length
          unless f.is_a?(Numeric)
            n = f.length if f.length < n
            f = f[0...n] if f.length > n
          end
          d = d[0...n] if d.length > n

          constant = constant_detune?(d)
          min = @range[0]
          # In :interp mode only once the ramp to it has finished
          constant = false if @mode == :interp && !(@state && @state[0] == @state[1] && @state[1] == Math.exp(min * LOG_SEMITONE))

          # A constant pitch and detune repeat the last frame (keeping the
          # control points on their grid)
          if constant && f.is_a?(Numeric) && f == @frame_f && min == @frame_d && @frame_n == n
            @state[2] = (@state[2].to_i + n) % @control if @state && @control
            return @views
          end

          make_frame(n)
          @frame_f = constant && f.is_a?(Numeric) ? f : nil
          @frame_d = min

          if @mode == :exact
            if constant
              Kernels.unison_scale(@data, f, exact_ratios(min))
            else
              Kernels.unison_exact(@data, f, d, @fractions)
            end
          else
            unless @state
              r = Math.exp(d[0] * LOG_SEMITONE)
              @state = Numo::DFloat[r, r, 0]
            end
            Kernels.unison_interp(@data, f, d, @positions, @state, @control || 0)
          end

          @views
        end

        # Forgets the frame at the end of an input (returns nil).
        def ended
          @data = nil
          @frame_f = nil
        end

        # True if every value of the detune buffer +d+ is the same (its
        # range in @range): checked once for a steady frozen buffer (a
        # constant node's, an unmoving knob's; GraphNode::FrozenView::Key),
        # without allocating (Kernels.min_max).
        def constant_detune?(d)
          return @steady_constant if @steady_key.match?(d)

          r = @range
          unless Kernels.min_max(d, r)
            r[0] = d.min.to_f
            r[1] = d.max.to_f
          end
          @steady_key.set(d)
          @steady_constant = r[0] == r[1]
        end

        # Every copy's exact ratio for a detune of +d+ semitones (the same
        # operations as the kernel's exact mode), kept for the last detune.
        def exact_ratios(d)
          return @ratios if @ratios_for == d

          x = d * LOG_SEMITONE
          @ratios_for = d
          @ratios = @fractions.map { |a| Math.exp(a * x) }
        end

        # Makes sure @data holds a count×n frame (keeping the other size's
        # frame for the next buffer of that size).
        def make_frame(n)
          return if @data && @frame_n == n

          data = @data
          views = @views
          old_n = @frame_n
          if @spare_data && @spare_n == n
            @data = @spare_data
            @views = @spare_views
          else
            @data = Numo::SFloat.zeros(@fractions.length, n)
            @views = Array.new(@fractions.length) { |i| @data[i, true] }
          end
          if data
            @spare_data = data
            @spare_views = views
            @spare_n = old_n
          end
          @frame_n = n
          @frame_f = nil
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

      Kernels.register :unison_exact, c: FastUnison.method(:exact), ruby: Detune::RubyKernel.method(:exact)
      Kernels.register :unison_interp, c: FastUnison.method(:interp), ruby: Detune::RubyKernel.method(:interp)
      Kernels.register :unison_scale, c: FastUnison.method(:scale), ruby: Detune::RubyKernel.method(:scale)
    end
  end
end
