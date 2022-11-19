require 'forwardable'

module MB
  module Sound
    module MIDI
      # A pool of oscillators managed by MIDI note-on and note-off events,
      # initially based on code from bin/ep2_syn.rb.
      class VoicePool
        include GraphNode
        extend Forwardable

        def_delegators :@voices, :each, :map

        # The last-triggered voice.
        attr_reader :last

        # The pitch bend amount, in fractional semitones.
        attr_reader :bend

        # Initializes an oscillator pool with the given array of oscillators.
        #
        # +manager+ - The MB::Sound::MIDI::Manager from which to receive MIDI events.
        # +voices+ - An Array of MB::Sound::MIDI::Voice or MB::Sound::MIDI::GraphVoice.
        # +:threaded+ - If true, each voice will be processed in a separate thread.  Only useful
        #               if the voices do most of their work in C code without the global
        #               interpreter lock.
        def initialize(manager, voices, threaded: false)
          @voices = voices

          if threaded
            @threads = @voices.map.with_index { |v, idx|
              size_in = Queue.new
              buf_out = Queue.new
              t = Thread.new do
                loop do
                  buf_out.push(v.sample(size_in.pop))
                end
              end

              t.name = "Voice pool voice #{idx + 1}/#{@voices.length}"

              {
                thread: t,
                size_in: size_in,
                buf_out: buf_out,
              }
            }
          end

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

          # Bind voice parameters to MIDI CCs
          # TODO: Only add one listener to the manager per CC instead of one per voice per CC
          if voices.all? { |v| v.respond_to?(:cc_map) }
            manager.on_cc_map(voices.map(&:cc_map))
          end

          if voices.all? { |v| v.respond_to?(:update) }
            manager.on_update { voices.each(&:update) }
          end
        end

        # Sets the names of threads in the thread pool based on the node name, if threading was
        # enabled in the constructor.
        def named(n)
          super

          @threads&.each&.with_index do |t, idx|
            t[:thread].name = "Voice pool #{graph_node_name} voice #{idx + 1}/#{@threads.length}"
          end

          self
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
        # needed.  Called by #midi_note.
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
          if @threads
            @threads.each do |t|
              t[:size_in].push(count)
            end

            @threads.map { |t| t[:buf_out].pop }.sum
          else
            @voices.map { |v| v.sample(count) }.sum
          end
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

        # Returns all of the voices in the pool that include GraphNode.
        def sources
          @voices.select { |v| v.is_a?(GraphNode) }
        end
      end
    end
  end
end
