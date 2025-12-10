require_relative 'midi_dsl/midi_value'
require_relative 'midi_dsl/midi_cc'
require_relative 'midi_dsl/midi_frequency'
require_relative 'midi_dsl/midi_number'
require_relative 'midi_dsl/midi_envelope'
require_relative 'midi_dsl/midi_tone'

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

        # The MIDI manager used by this DSL for receiving MIDI events from
        # files or MIDI interfaces.
        attr_reader :manager

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
          @envelopes = {}
          @reverse_cache = {}

          # TODO: make manager support nested managers for channel filtering
          # TODO: efficient branching of MIDI input and timestamp without creating an input for every object
          # TODO: means for GraphVoice to take over controls
          # TODO: maybe a DSL for wrapping a subset of a graph in a GraphVoice
          # TODO: maybe cache returned values so fewer nodes are created
          # TODO: maybe a true MIDI graph that processes, delays, etc. MIDI events on the wires
        end

        # TODO: returns a MIDI DSL handle that filters to the given channel (by
        # default the MIDI DSL responds to all channels).
        #
        # Example (in bin/sound.rb):
        #     play midi.channel(1).hz * midi.channel(1).env
        def channel(ch)
          return parent.channel(ch) if @parent

          @channels ||= []
          @channels[ch] ||= MidiDsl.new(manager: @manager, channel: ch, parent: self) # FIXME: need new manager

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
          cache(@ccs, [number, range, unit, si]) do
            MidiCc.new(dsl: self, number: number, range: range, unit: unit, si: si, sample_rate: 48000)
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
          cache(@freqs, [bend_range]) do
            MidiFrequency.new(dsl: self, bend_range: bend_range, sample_rate: 48000)
          end
        end

        # Returns a new Tone that will play at the frequency of incoming MIDI
        # notes, incorporating pitch bend.
        #
        # +:bend_range+ - The pitch bend range to add to the base note number,
        #                 in semitones.  E.g. pass -12..12 for a full octave.
        def hz(bend_range: DEFAULT_BEND_RANGE)
          cache(@tones, [bend_range]) do
            MidiTone.new(dsl: self, frequency: self.frequency(bend_range: bend_range))
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
          cache(@numbers, [range, bend_range, unit, si]) do
            MidiNumber.new(dsl: self, range: range, bend_range: bend_range, unit: unit, si: si, sample_rate: 48000)
          end
        end

        # Returns a new graph node that will output the MIDI attack velocity of
        # the last-pressed note scaled to 0..1 (or to the given +:range+).  If
        # the note +number+ is specified, then only the velocity of that note
        # is used and other notes are ignored.
        #
        # TODO: should this output zero or something based on release velocity when the note is released?
        # TODO: allow selecting just release velocity?
        def velocity(number = nil, range: 0..1, unit: nil, si: false)
          number = number.to_note if number.is_a?(MB::Sound::Tone)
          number = number.number if number.is_a?(MB::Sound::Note)

          raise NotImplementedError, 'TODO'
          cache(@velocities, [number, range, unit, si]) do
            MidiVelocity.new(dsl: self, number: number, range: range, unit: unit, si: si, sample_rate: 48000)
          end
        end

        # TODO: pitch bend
        def bend
          raise NotImplementedError, 'TODO'
        end

        # Returns a new ADSR envelope that will trigger based on velocity when
        # a note is pressed, and release when the note or sustain pedal are
        # released.
        def env(attack_s = nil, decay_s = nil, sustain_l = nil, release_s = nil, range: 0..1)
          attack_s ||= 0.002
          decay_s ||= 0.05
          sustain_l ||= -10.db
          release_s ||= 0.1

          key = [attack_s, decay_s, sustain_l, release_s, range]

          cache(@envelopes, key) do
            MB::Sound::GraphNode::MidiDsl::MidiEnvelope.new(
              dsl: self,
              attack: attack_s,
              decay: decay_s,
              sustain: sustain_l,
              release: release_s,
              sample_rate: 48000,
              range: range
            )
          end
        end

        def gate
          # TODO: start gate at correct offset within frame?  would need to get event timestamps out of mb-sound-jackffi

          raise NotImplementedError, 'TODO'
        end

        # Called by MIDI audio nodes to invalidate the cache e.g. when sampling
        # begins, so that new graphs at a possibly different sample rate get
        # new instances.
        #
        # TODO: this is still not the ideal approach, and it breaks if we just
        # send the graph to graphviz instead of playing it.
        def invalidate_cache(obj)
          collection, key = @reverse_cache[obj]
          return unless collection && key

          @reverse_cache.delete(collection)
          collection.delete(key)
        end

        # XXX FIXME hack for graph display
        def sources; {} end
        def spy(*a, **ka); end
        def clear_spies(*a, **ka); end
        def node_type_name; 'MIDI' end
        def to_s_graphviz; "MIDI #{@channel && "channel #{@channel}"}".strip end

        private

        # Used internally to save a bidirectional cache for the given MIDI
        # node.  Yields to create a new object if the key is not in the
        # collection.
        #
        # Resets the node's sample rate to 48000 in case there were prior
        # sample rate changes to the node in a previous graph.  This means that
        # .oversample is not fool-proof and can break graphs with parallel
        # paths at different sample rates.
        def cache(collection, key)
          # TODO: maybe #at_rate should behave differently for nodes with
          # multiple output branches, inserting a resampling step instead if
          # there are mismatched rates?
          # TODO: maybe change .oversample to return an object that always
          # maintains a sample rate multiple and always call #at_rate when
          # playing a graph?  yeah, fixing up sample rates each time playback
          # starts seems reasonable, but then what about a node that is
          # referenced in graphs that run at different rates?  Is having the
          # invisible graph tees more efficient than duplicating nodes?  Can we
          # deduplicate at the display stage instead?
          collection.fetch(key) {
            collection[key] = yield
              .tap { |node| @reverse_cache[node] = [collection, key] }
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
