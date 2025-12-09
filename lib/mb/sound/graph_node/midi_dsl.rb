require_relative 'midi_dsl/rate_decacher'
require_relative 'midi_dsl/midi_value'
require_relative 'midi_dsl/midi_cc'
require_relative 'midi_dsl/midi_frequency'
require_relative 'midi_dsl/midi_number'
require_relative 'midi_dsl/midi_envelope'

module MB
  module Sound
    module GraphNode
      # Starting point for MIDI integration in the GraphNode signal chain DSL.
      # The MidiDsl instance has methods for each type of MIDI message to
      # listen for, each method returning a graph node that can be chained just
      # like any other signal source.
      #
      # Example:
      #     play midi.hz.at(-6.db).ramp.filter(:lowpass, cutoff: (midi.frequency * midi.cc(1, range: 1.3..16)), quality: 4).oversample(16).softclip.oversample(2)
      class MidiDsl
        # The default pitch bend range for #hz, #frequency, and #number.
        # TODO: maybe allow specifying a different default bend range?
        DEFAULT_BEND_RANGE = -1..1

        # Creates a DSL instance with the given MIDI manager, filtering to the
        # given channel, and receiving from the given parent MidiDsl.  The
        # initial DSL has channel and parent nil, while filtered DSLs will set
        # them accordingly.
        def initialize(manager:, channel: nil, parent: nil)
          @manager = manager
          @channel = channel
          @parent = parent

          @freqs = {}
          @tones = {}
          @ccs = {}
          @numbers = {}
          @reverse_cache = {}

          # TODO: make manager support nested managers for channel filtering
          # TODO: efficient branching of MIDI input and timestamp without creating an input for every object
          # TODO: means for GraphVoice to take over controls
          # TODO: maybe a DSL for wrapping a subset of a graph in a GraphVoice
          # TODO: maybe cache returned values so fewer nodes are created
        end

        # TODO: returns a MIDI DSL handle that filters to the given channel (by
        # default the MIDI DSL responds to all channels).
        #
        # Example (in bin/sound.rb):
        #     play midi.channel(1).hz * midi.channel(1).env
        def channel(ch)
          return parent.channel(ch) if @parent

          @channels ||= []
          @channels[ch] ||= MidiDsl.new(channel: ch, parent: self)

          raise NotImplementedError, 'TODO: implement channel filtering without opening a new input'
        end

        # Returns a graph node that produces scaled values from MIDI control
        # change events.
        #
        # +number+ - Control change number (e.g. 1 for modwheel).
        # +:range+ - Output range
        # +:unit+ - Display unit (e.g. Hz if scaling to a frequency)
        # +:si+ - Whether to display 24000 as 24k.
        def cc(number, range: 0..1, unit: nil, si: false)
          # TODO: MSB/LSB?  NRPN?
          cache(@ccs, [number, range, unit, si, 48000]) do
            MidiCc.new(manager: @manager, number: number, range: range, unit: unit, si: si, sample_rate: 48000)
          end
        end

        # Returns a new graph node that will output a frequency value set by
        # note-on number and pitch bend.  The frequency value will remain the
        # same after the note is released, so use .env to create an ADSR
        # envelope based on MIDI note-on/note-off events.
        #
        # +:bend_range+ - The pitch bend range to add to the base note number,
        #                 in semitones.  E.g. pass -12..12 for a full octave.
        #
        # See #hz.
        def frequency(bend_range: DEFAULT_BEND_RANGE)
          cache(@freqs, [bend_range, 48000]) do
            MidiFrequency.new(manager: @manager, bend_range: bend_range, sample_rate: 48000)
          end
        end

        # Returns a new Tone that will play at the frequency of incoming MIDI
        # notes, incorporating pitch bend.
        #
        # +:bend_range+ - The pitch bend range to add to the base note number,
        #                 in semitones.  E.g. pass -12..12 for a full octave.
        def hz(bend_range: DEFAULT_BEND_RANGE)
          cache(@tones, [bend_range, 48000]) do
            self.frequency(bend_range: bend_range).tone.or_for(nil)
          end
        end
        alias tone hz

        # Returns a new graph node that will generate the MIDI note number on
        # its output, optionally scaled to a given new range.  Pitch bend is
        # included by default.
        #
        # +:range+ - The range to output, or nil for the raw 0..127 number.
        # +:bend_range+ - The pitch bend range in semitones, or nil to ignore
        #                 pitch bend.
        def number(range: nil, bend_range: DEFAULT_BEND_RANGE, unit: nil, si: false)
          cache(@numbers, [range, bend_range, unit, si, 48000]) do
            MidiNumber.new(manager: @manager, range: range, bend_range: bend_range, unit: unit, si: si, sample_rate: 48000)
          end
        end

        # Returns a new graph node that will output the MIDI attack velocity of
        # the last-pressed note scaled to 0..1 (or to the given +:range+).  If
        # the note +number+ is specified, then only the velocity of that note
        # is used and other notes are ignored.
        #
        # TODO: should this output zero or something based on release velocity when the note is released?
        # TODO: allow selecting just release velocity?
        def velocity(number = nil, range: 0..1)
          number = number.to_note if number.is_a?(MB::Sound::Tone)
          number = number.number if number.is_a?(MB::Sound::Note)

          raise NotImplementedError, 'TODO'
          MidiVelocity.new(manager: @manager, number: number, range: range)
        end

        # TODO: pitch bend
        def bend
          raise NotImplementedError, 'TODO'
        end

        # Returns a new ADSR envelope that will trigger based on velocity when
        # a note is pressed, and release when the note or sustain pedal are
        # released.
        def env(attack_s = nil, decay_s = nil, sustain_l = nil, release_s = nil)
          attack_s ||= 0.005
          decay_s ||= 0.02
          sustain_l ||= -10.db
          release_s ||= 0.1

          MB::Sound::GraphNode::MidiDsl::MidiEnvelope.new(
            manager: @manager,
            attack: attack_s,
            decay: decay_s,
            sustain: sustain_l,
            release: release_s,
            sample_rate: 48000
          )
        end

        def gate
          # TODO: start gate at correct offset within frame?  would need to get event timestamps out of mb-sound-jackffi

          raise NotImplementedError, 'TODO'
        end

        # For internal use.  Called by MIDI nodes when their sample rate changes.
        def rate_changed(node)
          collection, key = @reverse_cache[node]

          unless collection && key
            warn "BUG: Got a sample rate change notification for an unknown node: #{node}"
            return
          end

          key[-1] = node.sample_rate
        end

        private

        # Used internally to save a bidirectional cache for the given MIDI
        # node.  Yields to create a new object if the key is not in the
        # collection.  The +key+ must be mutable to allow sample rate changes,
        # and the last element in the key must be the starting sample rate.
        #
        # TODO: maybe instead of re-caching based on sample rate, we should
        # just reset the sample rate?  This might work better with graphs with
        # .oversample().
        def cache(collection, key)
          collection[key] ||= yield.tap { |node|
            @reverse_cache[node] = [collection, key]
            node.singleton_class.include(RateDecacher) unless node.is_a?(RateDecacher)
            node.instance_variable_set(:@midi_dsl, self) # this is rude
          }
        end
      end
    end

    # Returns a handle for connecting MIDI events to GraphNode networks.  See
    # MidiDsl for details.
    def self.midi
      # TODO: allow specifying an input/connection by name and then caching the DSL for that input?
      # TODO: maybe move this method into sound.rb?
      @midi_manager ||= MB::Sound::MIDI::Manager.new
      @midi_dsl ||= MB::Sound::GraphNode::MidiDsl.new(manager: @midi_manager)
    end
  end
end
