module MB
  module Sound
    # The plan layer side of envelopes (see MB::Sound::Plan and
    # Plan::Op::Envelope): an envelope describes itself as one envelope op
    # with its node parameters and inputs as Values.
    #
    # Inputs that aren't in the envelope's region are read as optional
    # boundary inputs: when one ends, the block replays unfused (the
    # envelope then reads the input's ended value as #sample does: 0 for
    # gates, triggers, and chokes, else its last value, which the plan keeps
    # up to date for boundary inputs), and the input is a constant at its
    # ended value from the next plan on.
    class Envelope
      include Plan::Describable

      # The kernel's state (an Array of STATE_* values in a DFloat).
      def plan_state
        @state
      end

      # The kernel's segment shapes (FastEnvelope numbers).
      def plan_shapes
        @names.map { |s| SHAPES.fetch(@shapes[s]) }
      end

      # Per-block Ruby (see Plan::EventList): nothing for plain envelopes
      # (Notes::NoteEnvelope counts stream time).
      def plan_feed(count)
      end

      # True once a one-shot has ended (#sample returns nil from then on).
      def plan_finished?
        ended?
      end

      def plan_inputs
        sources.each_value.select { |v| v.respond_to?(:sample) }
      end

      def plan_describe(p)
        times = @names.map { |s| plan_length(p, s, @times[s]) }
        curves = @names.map { |s| plan_param(p, curve_key(s), @curves[s]) }
        levels = @names.map { |s| plan_param(p, level_key(s), @levels[s]) }
        hold_source = @hold == false ? nil : (@hold || default_hold)
        hold = hold_source.nil? ? p.const(Float::INFINITY) : plan_length(p, :hold, hold_source)

        p.envelope(
          self, times: times, curves: curves, levels: levels, hold: hold,
          gate: plan_param(p, :gate, @gate), trigger: plan_param(p, :trigger, @trigger),
          velocity: plan_param(p, :velocity, @velocity), choke: plan_param(p, :choke, @choke),
          lift: plan_param(p, :lift, @lift), octaves: plan_param(p, :octaves, @octaves)
        )
      end

      # Called by a region when the optional boundary input +source+ ended:
      # the block replays unfused, and the input is a constant from the next
      # plan on (see the description above).
      def plan_input_ended(source)
        (@plan_ended ||= {}.compare_by_identity)[source] = true
        Plan.changed(self)
        :replay
      end

      # True: short buffers from inputs are padded (see #fit), so a block
      # with one runs unfused (see Plan::Region#gather).
      def plan_pads_inputs?
        true
      end

      def plan_snapshot
        Plan::Snapshot.capture(self, [:@state])
      end

      def plan_restore(snapshot)
        @state[0..] = snapshot.data[:@state]
      end

      private

      # The value #sample reads for input or parameter +key+ after its node
      # ended (see #read_input, #fit).
      def plan_ended_value(key)
        case key
        when :gate, :trigger, :choke then 0.0
        when :velocity then @last.fetch(:velocity, 1.0)
        when :lift then @last.fetch(:lift, 0.5)
        else @last.fetch(key, 0.0)
        end
      end

      # A node parameter or input as a Value (its real part), nil, or a
      # number (see the description above).
      def plan_param(p, key, value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        node = Plan.origin(value)
        return plan_ended_value(key) if @plan_ended&.key?(node)

        v = p.optional(value)
        v = v.real if v.complex?
        p.keep_last(v, @last, key) if v.op.is_a?(Plan::Op::Input) || v.op.is_a?(Plan::Op::Part) && v.op.a.op.is_a?(Plan::Op::Input)
        v
      end

      # A length (Length::Source) in samples as a Value or number.
      def plan_length(p, key, source)
        return source.constant_samples(@sample_rate) unless source.node?

        node = Plan.origin(source.node)
        return plan_ended_value(key) if @plan_ended&.key?(node)

        v = p.optional(source.node)
        boundary = v.op.is_a?(Plan::Op::Input)
        v = v.real if v.complex?
        v = v * @sample_rate if source.unit == :seconds
        p.keep_last(v, @last, key) if boundary
        v
      end
    end
  end
end
