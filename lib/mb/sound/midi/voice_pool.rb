require 'forwardable'

module MB
  module Sound
    module MIDI
      # A pool of oscillators managed by MIDI note-on and note-off events,
      # initially based on code from bin/ep2_syn.rb.
      class VoicePool
        extend Forwardable

        def_delegators :@voices, :each, :map

        # The last-triggered voice.
        attr_reader :last

        # The pitch bend amount, in fractional semitones.
        attr_reader :bend

        # Initializes an oscillator pool with the given array of oscillators.
        def initialize(manager, voices)
          @voices = voices
          @available = voices.dup
          @used = []
          @key_to_value = {}
          @value_to_key = {}
          @sustain = false
          @last = voices.last
          @bend = 0
          @released = {}

          manager.on_note(&method(:midi_note))
          manager.on_cc_threshold(64, 64, 64, &method(:sustain))
        end

        # Called by the MIDI manager when a note on or off event is received.
        def midi_note(note, velocity, onoff)
          if onoff
            @released.delete(note)
            trigger(note, velocity)

          else
            # TODO: Move sustain handling into Manager?
            if !@sustain
              release(note)&.release(note, velocity)
            else
              @released[note] = velocity
            end
          end
        end

        # Called by the MIDI manager when the sustain CC rises above or below
        # the sustain threshold.
        def sustain(_, value, onoff)
          # TODO: it would be cool to support variable sustain by decreasing
          # the envelope release time or something
          if (!onoff && @sustain) || value == 0
            release_sustain
          end

          @sustain = onoff
        end

        # Finds and triggers the next available voice, reusing a voice if
        # needed.  Called by #midi_event.
        def trigger(note, velocity)
          @last = self.next(note)
          @last.trigger(note + @bend, velocity)
        end

        # Bends all playing and future notes by the given number of semitones.
        def bend=(bend)
          delta = bend - @bend
          @bend = bend.to_f
          @key_to_value.each do |k, osc|
            osc.number = k + @bend
          end
          @available.each do |osc|
            osc.number += delta
          end
        end

        # Starts the release phase of all pressed notes.
        def all_off
          @key_to_value.each do |k, _|
            self.release(k)&.release(k, 0)
          end
        end

        # Starts the release phase of notes not currently held (On but no Off),
        # for when the sustain pedal is released.
        def release_sustain
          @released.each do |note, velocity|
            self.release(note)&.release(note, velocity)
          end
          @released.clear
        end

        # Returns true if there are any sounding notes.
        def active?
          @voices.any?(&:active?)
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
