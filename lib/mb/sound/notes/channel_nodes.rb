module MB
  module Sound
    class Notes
      # Base for channel-wide values (controllers, bend, pressure), which
      # Notes shares among every Notes instance on the same control stream
      # (see Notes.control_stream).  Reset all controllers (CC 121) returns
      # the value to its default where MIDI RP-15 says so (see #reset?).
      class ChannelNode < Node::Held
        # The current value.
        def value
          level
        end

        private

        def handle(event)
          if event.reset_controllers?
            reset_value if reset?
          else
            update(event)
          end
        end

        # Updates the value from +event+.
        def update(event)
          raise NotImplementedError
        end

        # True if reset all controllers resets this value.
        def reset?
          true
        end

        # Returns the value to its default.
        def reset_value
          raise NotImplementedError
        end
      end

      # Pitch bend (see Notes#bend and Notes#bend_semitones): -1..1, or
      # semitones with the stream's bend range (MIDI::Event#bend_semitones)
      # or a fixed range.
      class Bend < ChannelNode
        # The output unit: nil for -1..1, :stream for semitones with the
        # stream's bend range, or a number of semitones for full bend.
        attr_reader :range

        def initialize(stream, range: nil, sample_rate: 48000)
          super(stream, sample_rate: sample_rate)
          raise ArgumentError, "Bend range must be nil, :stream, or semitones (got #{range.inspect})" unless range.nil? || range == :stream || range.is_a?(Numeric)

          @range = range
          @bend = 0.0
          @event_range = nil
          @node_type_name = range.nil? ? 'Notes Bend' : "Notes Bend (#{range == :stream ? 'semitones' : "#{range} st"})"
        end

        private

        def level
          case @range
          when nil then @bend
          when :stream then @bend * (@event_range || MIDI::Event::DEFAULT_BEND_RANGE).to_f
          else @bend * @range
          end
        end

        def update(event)
          return unless event.type == :bend
          @bend = event.value.to_f
          @event_range = event.bend_range
        end

        def reset_value
          @bend = 0.0
        end
      end

      # Channel pressure (aftertouch), 0..1 (see Notes#pressure).
      class Pressure < ChannelNode
        def initialize(stream, sample_rate: 48000)
          super(stream, sample_rate: sample_rate)
          @pressure = 0.0
          @node_type_name = 'Notes Pressure'
        end

        private

        def level
          @pressure
        end

        def update(event)
          @pressure = event.value.to_f if event.type == :channel_pressure
        end

        def reset_value
          @pressure = 0.0
        end
      end
    end
  end
end
