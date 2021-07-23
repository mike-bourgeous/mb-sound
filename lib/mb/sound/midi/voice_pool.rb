require 'forwardable'

module MB
  module Sound
    module MIDI
      # A pool of oscillators managed by MIDI note-on and note-off events,
      # initially based on code from bin/ep2_syn.rb.
      class VoicePool
        extend Forwardable

        def_delegators :@voices, :each, :map

        # Initializes an oscillator pool with the given array of oscillators.
        def initialize(manager, voices)
          @voices = voices
          @available = voices.dup
          @used = []
          @key_to_value = {}
          @value_to_key = {}

          manager.on_event(&method(:midi_event))
        end

        # Called by the MIDI manager when a MIDI event is received.
        def midi_event(e)
          case e
          when MIDIMessage::NoteOn
            self.next(e.note).trigger(e.note, e.velocity)

          when MIDIMessage::NoteOff
            self.release(e.note)&.release(e.note, e.velocity)
          end
        end

        # Samples and sums the current output of all voices/oscillators.
        # Assumes all voices given to the constructor have a #sample method.
        def sample(count)
          @voices.map { |v| v.sample(count) }.sum
        end

        # Called internally.  Retrieves the next available (or stolen)
        # oscillator to play +key+.
        def next(key)
          if @key_to_value.include?(key)
            # Reusing the oscillator that's already playing this key
            return @key_to_value[key]
          elsif !@available.empty?
            # Using an unused oscillator
            value = @available.shift
            @key_to_value[key] = value
            @value_to_key[value] = key
            @used << value
            return value
          elsif !@used.empty?
            # Stealing an oscillator already in use
            value = @used.shift
            old_key = @value_to_key[value]
            @key_to_value.delete(old_key)
            @value_to_key.delete(value)
            @key_to_value[key] = value
            @value_to_key[value] = key
            @used << value
            return value
          else
            raise 'BUG: both used and available are empty'
          end
        end

        # Called internally.  Adds the oscillator associated with this +key+ to
        # the available pool and returns the oscillator.  Returns nil if the
        # oscillator was recycled.
        def release(key)
          if @key_to_value.include?(key)
            value = @key_to_value[key]
            @used.delete(value)
            @key_to_value.delete(key)
            @value_to_key.delete(value)
            @available << value
            value
          else
            nil
          end
        end
      end
    end
  end
end
