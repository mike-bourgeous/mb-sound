module MB
  module Sound
    # Values that move (knobs-1, 2026-10-30; arch-session section 1): the
    # one place that accepts "a number, a knob name, a knob, or a node" and
    # the one way to read such a value at a moment.
    #
    # Two kinds of readers take them:
    #
    # - **Per sample** (+read: :sample+): what a knob turns to or follows
    #   (`turn`, scene and section knob values), send levels, rack control
    #   ports, graph-document params bound to the caller's nodes.  Nodes are
    #   followed every sample, so any graph node works.
    # - **At decision points** (+read: :decision+): clock speeds, followed
    #   tempos, MIDI transforms' and generators' options.  These read a value
    #   once per note, step, cycle, or 800-frame cell, so nodes must be ones
    #   a timeline position answers for (MIDI::Param.wrap: knobs, tempo LFOs,
    #   constants, sums and products of those, clips, cc params); audio-rate
    #   nodes raise MIDI::Param::NotAParam, which names a knob that follows
    #   them instead.
    #
    # Both read through one protocol, every moving value's #value_at:
    #
    #     value_at(pos, frame: nil, transport: nil, stream: nil)
    #
    # +pos+ is a timeline position (Rational whole notes), +frame+ the
    # Session frame it falls on when the caller knows it (clocks and tempos
    # read at exact frames), +transport+ the reader's Sequence::Transport,
    # and +stream+ a MIDI transform's MIDI::Param::Reading.  Knobs, their
    # Readers, MIDI::Params, and Clips answer it; .value_at reads anything
    # (plain values answer themselves, knob names through a Session).
    module ValueSource
      module_function

      # +value+ checked as a value that moves, ready for its reader: plain
      # numbers (real and finite, and within +numbers+, a Range or a Proc,
      # when given; +numbers: false+ refuses them), knob names (Symbols;
      # +names:+ :keep keeps the name, :check also checks that +knobs+ (a
      # Session) has it, :knob gives the Session's Knob, false refuses
      # names), Knobs and Readers as they are, and nodes: any graph node
      # for +read: :sample+ (and bundles with +channels: true+), the nodes
      # MIDI::Param.wrap reads (plus clips and params) for +read:
      # :decision+.  Raises ArgumentError naming +what+, what it takes, and
      # +number_hint+ (e.g. "is a gain from 0 to 4") for numbers it
      # refuses; MIDI::Param::NotAParam for audio-rate nodes read at
      # decision points.
      def coerce(value, what, read: :sample, numbers: nil, number_hint: nil, names: :keep, knobs: nil, channels: false)
        case value
        when Numeric
          refused(value, what, read, numbers, names, channels) if numbers == false
          ok = value.real? && value.finite? && (numbers.nil? || numbers === value)
          raise ArgumentError, "#{what} #{number_hint || 'takes a real, finite number'} (got #{value.inspect})" unless ok
          value

        when Symbol
          refused(value, what, read, numbers, names, channels) unless names
          return value if names == :keep
          raise ArgumentError, "#{what} names knob #{value.inspect}, but there is no Session" unless knobs
          k = begin
                knobs.knob!(value)
              rescue ArgumentError => e
                raise ArgumentError, "#{what}: #{e.message}"
              end
          names == :knob ? k : value

        when GraphNode::Knob, GraphNode::Knob::Reader
          value

        else
          if read == :decision
            return value if value.is_a?(MIDI::Param::Base)
            return MIDI::Param.wrap(value, what) if value.is_a?(GraphNode) || value.is_a?(Sequence::Clip)
          else
            return value if value.respond_to?(:sample) && value.respond_to?(:get_sampler)
            return value if channels && value.is_a?(GraphNode::Channels)
          end
          refused(value, what, read, numbers, names, channels)
        end
      end

      # The value of +x+ at timeline position +pos+ (see the module
      # description for the keywords): moving values through their
      # #value_at, plain values as they are.  Symbols are values (lock
      # styles, modes) unless +knobs+ (a Session) is given: then they name
      # its knobs.  +now: true+ reads knobs at their current value (a clock
      # outside a Session, which has no session frame to read them at).
      def value_at(x, pos, frame: nil, transport: nil, stream: nil, knobs: nil, now: false)
        x = knobs.knob!(x) if knobs && x.is_a?(Symbol)
        if now
          return x.value if x.is_a?(GraphNode::Knob)
          return x.knob.value if x.is_a?(GraphNode::Knob::Reader)
        end
        x.respond_to?(:value_at) ? x.value_at(pos, frame: frame, transport: transport, stream: stream) : x
      end

      # The Knob behind +x+ (a Knob, or a Reader of one), else nil.
      def knob_of(x)
        return x if x.is_a?(GraphNode::Knob)
        x.is_a?(GraphNode::Knob::Reader) ? x.knob : nil
      end

      # Raises for +value+, which the reader doesn't take, listing what it
      # does.
      def refused(value, what, read, numbers, names, channels)
        takes = []
        takes << 'a number' unless numbers == false
        takes << 'a knob name' if names
        takes << 'knob(:x)'
        takes << (read == :decision ? 'a param like cc(1, 0.5..2) or 4.bars.lfo.at(0.5..2)' : 'a node')
        takes << 'a bundle' if channels
        list = takes.length > 1 ? "#{takes[0..-2].join(', ')}, or #{takes[-1]}" : takes[0]
        desc = begin
                 value.nil? ? 'nil' : ArgTypes.describe_value(value)
               rescue StandardError
                 value.inspect
               end
        raise ArgumentError, "#{what} takes #{list} (got #{desc})"
      end
      private_class_method :refused
    end
  end
end
