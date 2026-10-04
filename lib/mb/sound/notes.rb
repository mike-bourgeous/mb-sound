require 'weakref'

module MB
  module Sound
    # Signal nodes for the notes and controllers of a MIDI stream, for MIDI
    # and clips alike: the per-voice (or mono) DSL of the new pull-based
    # MIDI layer (see MIDI::Stream).  Synth blocks and the console call an
    # instance +v+.  Construct it from a MIDI::Stream (or a transformed
    # view of one), a MIDI::Source, a Sequence::Clip, a MIDIFile, or a MIDI
    # filename (see MIDI::Stream.for).
    #
    # Every node is sample-exact: events land on their exact samples at the
    # node's own sample rate (see Notes::Node), on the same samples as
    # ClipNode for clips.  Nodes are made once per Notes instance and
    # reused (consumers branch them through Tees as usual); controller
    # nodes (#cc, #bend, #pressure and the named controls) are shared by
    # every Notes instance reading the same control stream, so every lane
    # of a synth shares one node per controller (see Notes.control_stream).
    #
    # Mono behavior: when the stream has overlapping notes (no allocator),
    # the newest note wins.  The gate stays high while any note is held, the
    # trigger fires at every note-on, and the note number follows the newest
    # held note, returning to the previous one when it is released.  Notes
    # are counted per (channel, note), so overlapping notes on one key (on,
    # on, off, off) stay held until the last note-off.  After content jumps
    # (seeks, timeline jumps, clip swaps), held values jump to the note at
    # the new position (see MIDI::Source#chase).
    #
    # Examples:
    #     v = MB::Sound::Notes.new(seq(C3, E3, G3).n8.loop)
    #     play v.hz.saw * v.gate
    #     v.number.smooth(0.05, reset: v.trigger)
    #
    # In progress (step D of the MIDI flow plan): the Allocator, synth
    # wiring, and the clip/console/script integration come later.
    class Notes
      # The note number held before the first note when the source can't
      # tell its first note (C4).
      DEFAULT_NUMBER = 60.0

      # Shared channel-wide nodes per control stream (see .control_stream):
      # stream => { key => WeakRef(node) }.
      SHARED = ObjectSpace::WeakKeyMap.new

      # Returns the stream whose channel-wide nodes (controllers, bend,
      # pressure) +stream+ shares: +stream+ itself, or for a voice stream
      # split from another by an allocator, the stream it was split from.
      #
      # Protocol (for the Allocator, built in parallel): a Source whose
      # #control_parent returns a MIDI::Stream marks its stream as a lane of
      # that stream, so every lane's Notes shares one node per controller,
      # read from the parent.  Transforms (channel, transpose, ...) don't
      # define it, since they change what the stream carries.
      def self.control_stream(stream)
        s = stream
        while s.source.respond_to?(:control_parent) && (parent = s.source.control_parent)
          s = parent
        end
        s
      end

      # The MIDI::Stream this instance reads.
      attr_reader :stream

      # The sample rate of nodes made from now on (graphs change it as
      # usual; see GraphNode::SampleRateHelper).
      attr_reader :sample_rate

      # Creates a Notes instance reading +source+ (see the class
      # description).
      def initialize(source, sample_rate: 48000)
        @stream = MIDI::Stream.for(source)
        @control_stream = Notes.control_stream(@stream)
        @sample_rate = sample_rate.to_f
        @nodes = {}
        @envelopes = []
      end

      # The stream read by channel-wide nodes (see .control_stream).
      attr_reader :control_stream

      # 1 while any note is held, else 0 (a Notes::Gate).
      def gate
        memo(:gate) { Gate.new(@stream, notes: self, sample_rate: @sample_rate) }
      end

      # A single-sample impulse at every note-on, valued at its velocity
      # (0..1; a Notes::Trigger).  Inputs that take triggers (Tone#reset,
      # Envelope +:trigger+, #smooth +reset:+) react to its rising edges.
      def trigger
        memo(:trigger) { Trigger.new(@stream, notes: self, sample_rate: @sample_rate) }
      end

      # The note number of the newest held note, held after release (a
      # Notes::Number), starting at the source's first note (or C4).
      def number
        memo(:number) { Number.new(@stream, notes: self, sample_rate: @sample_rate) }
      end
      alias note_number number

      # The velocity (0..1) of the latest note-on (a Notes::Velocity).
      def velocity
        memo(:velocity) { Velocity.new(@stream, notes: self, sample_rate: @sample_rate) }
      end

      # The release velocity (0..1) of the latest note-off (a Notes::Lift),
      # 64/127 until the first one.
      def lift
        memo(:lift) { Lift.new(@stream, notes: self, sample_rate: @sample_rate) }
      end
      alias release_velocity lift

      # A single-sample impulse of 1 at every :choke event (see
      # MIDI::Event.choke) and all sound off (CC 120) (a Notes::Choke).
      # Envelopes from this instance release over Envelope::CHOKE_TIME at
      # each one.
      def choke
        memo(:choke) { Choke.new(@stream, notes: self, sample_rate: @sample_rate) }
      end

      # The frequency in Hz of #number plus pitch bend (MIDI::Event#bend_semitones,
      # with the stream's bend range) through the session Tuning (a
      # Notes::Frequency).
      def freq
        memo(:freq) { Frequency.new(number, offsets: [bend_semitones], sample_rate: @sample_rate) }
      end
      alias frequency freq

      # Pitch bend, -1..1 (a Notes::Bend shared by every Notes instance on
      # the control stream).
      def bend
        shared(:bend) { Bend.new(@control_stream, sample_rate: @sample_rate) }
      end

      # Pitch bend in semitones (a shared Notes::Bend): with +range+ nil,
      # the stream's bend range (2 semitones unless RPN 0 or
      # MIDI::Stream#bend_range changes it; see MIDI::Event#bend_semitones),
      # or +range+ (an Interval or semitones, e.g. `12.st`) for full bend.
      def bend_semitones(range = nil)
        range = range.nil? ? :stream : Interval.semitones(range).to_f
        shared([:bend, range]) { Bend.new(@control_stream, range: range, sample_rate: @sample_rate) }
      end

      # Channel pressure (aftertouch), 0..1 (a shared Notes::Pressure).
      def pressure
        shared(:pressure) { Pressure.new(@control_stream, sample_rate: @sample_rate) }
      end
      alias aftertouch pressure

      # The envelopes made through this instance (see #env).
      def envelopes
        @envelopes.dup
      end

      # Records +envelope+ as one of this instance's envelopes, so #idle?
      # waits for it.  Envelope helpers call this.  Returns +envelope+.
      def register(envelope)
        @envelopes << envelope unless @envelopes.any? { |e| e.equal?(envelope) }
        envelope
      end

      # True when every envelope made through this instance (see #env,
      # #register) is idle, so a voice allocator can reuse the voice.  True
      # if there are none.
      def idle?
        @envelopes.all?(&:idle?)
      end

      # True once the stream's source has ended and every reader has read
      # every event.
      def ended?
        @stream.ended?
      end

      def to_s
        "Notes (#{@stream})"
      end

      private

      # Returns the node cached under +key+, or makes one with the block and
      # caches it.  The cache holds weak references, so nodes nobody uses
      # don't keep stream events (each node has its own reader).
      def memo(key)
        node = live(@nodes[key])
        return node if node

        node = yield
        @nodes[key] = WeakRef.new(node)
        node
      end

      # Like #memo, but shared by every Notes instance on the same control
      # stream (see .control_stream).
      def shared(key)
        cache = (SHARED[@control_stream] ||= {})
        node = live(cache[key])
        return node if node

        node = yield
        cache[key] = WeakRef.new(node)
        node
      end

      # The object behind +ref+ (a WeakRef), or nil if it's gone.
      def live(ref)
        ref&.weakref_alive? ? ref.__getobj__ : nil
      rescue WeakRef::RefError
        nil
      end
    end
  end
end

require_relative 'notes/node'
require_relative 'notes/note_stack'
require_relative 'notes/note_nodes'
require_relative 'notes/channel_nodes'
require_relative 'notes/frequency'
