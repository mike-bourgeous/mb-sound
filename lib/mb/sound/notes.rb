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
    # MB::Sound::Synth builds one Notes per MIDI::Allocator lane (step F2
    # of the MIDI flow plan); the clip/console/script integration comes
    # later.
    class Notes
      # The note number held before the first note when the source can't
      # tell its first note (C4).
      DEFAULT_NUMBER = 60.0

      # GM and GM2 controllers with standard numbers, ranges, and defaults,
      # each available as a method returning its shared node (e.g. #mod,
      # #brightness).  The sound controllers (70-79) are relative around
      # their default of 64, as in GM2.  Ranges (judgment calls where GM2
      # only says "relative"):
      # - attack/decay/release_time: a time multiplier, x1/8 at 0, x1 at 64,
      #   x8 at 127 (exponential), used by envelope .gm scaling (see #env);
      # - brightness: a cutoff multiplier of +-2 octaves (see #cutoff);
      # - resonance: a quality multiplier x0.5..x1..x4 (see #quality);
      # - vibrato_rate: 5.5 Hz at 64, x1/4..x4; vibrato_depth: a depth
      #   multiplier 0..1..2 (linear); vibrato_delay: 0 s up to 64, then up
      #   to 2 s (see NotePitch#vibrato);
      # - portamento_time: 2 ms at 0 to 5 s at 127, exponential (100 ms at
      #   64; see NotePitch#glide);
      # - volume (7), balance (8), pan (10), and expression (11) are not
      #   used by default (synth output controls are opt-in).
      GM_CONTROLS = {
        mod: { number: 1, name: 'Modulation', description: 'Mod wheel (vibrato depth for NotePitch#vibrato)' },
        breath: { number: 2, name: 'Breath' },
        foot: { number: 4, name: 'Foot' },
        portamento_time: {
          number: 5, name: 'Portamento Time', range: 0.002..5.0, curve: :exponential,
          description: 'Glide time in seconds (NotePitch#glide(:gm))',
        },
        volume: { number: 7, name: 'Volume', default: 100 },
        balance: { number: 8, name: 'Balance', range: -1.0..1.0, center: 0, default: 64 },
        pan: { number: 10, name: 'Pan', range: -1.0..1.0, center: 0, default: 64 },
        expression: { number: 11, name: 'Expression', default: 127 },
        portamento: { number: 65, name: 'Portamento', curve: :switch, description: 'Glide on/off (NotePitch#glide(:gm))' },
        resonance: {
          number: 71, name: 'Resonance', range: 0.5..4.0, center: 1, curve: :exponential, default: 64,
          description: 'Filter quality multiplier (Notes#quality)',
        },
        release_time: {
          number: 72, name: 'Release Time', range: 0.125..8.0, center: 1, curve: :exponential, default: 64,
          description: 'Envelope release time multiplier (.gm)',
        },
        attack_time: {
          number: 73, name: 'Attack Time', range: 0.125..8.0, center: 1, curve: :exponential, default: 64,
          description: 'Envelope attack time multiplier (.gm)',
        },
        brightness: {
          number: 74, name: 'Brightness', range: 0.25..4.0, center: 1, curve: :exponential, default: 64,
          description: 'Filter cutoff multiplier, +-2 octaves (Notes#cutoff)',
        },
        decay_time: {
          number: 75, name: 'Decay Time', range: 0.125..8.0, center: 1, curve: :exponential, default: 64,
          description: 'Envelope decay time multiplier (.gm)',
        },
        vibrato_rate: {
          number: 76, name: 'Vibrato Rate', range: 1.375..22.0, center: 5.5, curve: :exponential, default: 64,
          description: 'Vibrato rate in Hz (NotePitch#vibrato)',
        },
        vibrato_depth: {
          number: 77, name: 'Vibrato Depth', range: 0.0..2.0, center: 1, default: 64,
          description: 'Vibrato depth multiplier (NotePitch#vibrato)',
        },
        vibrato_delay: {
          number: 78, name: 'Vibrato Delay', range: 0.0..2.0, center: 0, default: 64,
          description: 'Vibrato fade-in time in seconds (NotePitch#vibrato)',
        },
        reverb_send: { number: 91, name: 'Reverb Send', default: 40 },
        chorus_send: { number: 93, name: 'Chorus Send' },
      }.transform_values { |h| MIDI::ControlSpec.new(**h).freeze }.freeze

      # Shared channel-wide nodes per control stream (see .control_stream):
      # stream => { key => WeakRef(node) }.
      SHARED = ObjectSpace::WeakKeyMap.new

      # Returns the stream whose channel-wide nodes (controllers, bend,
      # pressure) +stream+ shares: +stream+ itself, or for a voice stream
      # split from another by an allocator, the stream it was split from.
      #
      # A lane of an allocator (anything with #allocator whose allocator has
      # a #stream, like MIDI::Allocator::Lane on the allocator branch) and a
      # stream or Source with a #control_parent Stream are lanes of that
      # stream, so every lane's Notes shares one node per controller, read
      # from the parent.  Transforms (channel, transpose, ...) don't count,
      # since they change what the stream carries.
      def self.control_stream(stream)
        s = stream
        while (parent = control_parent(s))
          s = parent
        end
        s
      end

      # The stream +stream+ was split from as a lane, or nil (see
      # .control_stream).
      def self.control_parent(stream)
        if stream.respond_to?(:control_parent)
          stream.control_parent
        elsif stream.respond_to?(:allocator) && stream.allocator.respond_to?(:stream)
          stream.allocator.stream
        elsif stream.source.respond_to?(:control_parent)
          stream.source.control_parent
        end
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

      # A MIDI controller as a shared Notes::Control node (one per control
      # stream and spec), mapped linearly from raw 0..127 to +range+ (see
      # MIDI::ControlSpec for other mappings; pass a spec to #control),
      # starting at the raw +default+ (0..127).
      #
      #     v.cc(1)                        # mod wheel, 0..1
      #     v.cc(16, range: 200..2000)     # general purpose 1 as a cutoff
      def cc(number, range: 0.0..1.0, default: 0, name: nil, description: nil)
        control(MIDI::ControlSpec.new(number: number, range: range, default: default, name: name, description: description))
      end

      # A shared Notes::Control node for a MIDI::ControlSpec (see #cc).
      def control(spec)
        shared([:cc, spec]) { Control.new(@control_stream, spec, sample_rate: @sample_rate) }
      end

      GM_CONTROLS.each do |name, spec|
        define_method(name) { control(spec) }
      end
      alias modulation mod
      alias mod_wheel mod
      alias breath_controller breath
      alias foot_controller foot
      alias sound_brightness brightness
      alias timbre resonance

      # The MIDI::ControlSpecs of the controller nodes in use on this
      # instance's control stream (shared by every Notes instance there),
      # sorted by controller number, for control lists and ACID XML.
      def controls
        cache = SHARED[@control_stream] || {}
        cache.values.filter_map { |ref| live(ref) }.grep(Control).map(&:spec).uniq.sort_by { |s| [s.number, s.name] }
      end

      # Channel pressure (aftertouch), 0..1 (a shared Notes::Pressure).
      def pressure
        shared(:pressure) { Pressure.new(@control_stream, sample_rate: @sample_rate) }
      end
      alias aftertouch pressure

      # Envelope helpers: the MB::Sound::EnvelopeMethods presets (positional
      # attack, decay, sustain, release, plus any Envelope options) as
      # Notes::NoteEnvelopes wired to this instance's #gate, #trigger,
      # #velocity, and #choke, registered for #idle?.  +lift: true+ also
      # wires #lift (release velocity scales the release time; off by
      # default), or pass a node.  GM2 time scaling (NoteEnvelope#gm) is on
      # unless +gm: false+ or `.gm(false)`.
      #
      #     play v.hz.saw * v.amp_env(0.01, 0.3, 0.6, 0.5)
      #     v.filt_env(0, 0.4, 0.3, 0.3, depth: 3).gm(false)
      def env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        note_envelope(:env, attack, decay, sustain, release, **options)
      end
      alias envelope env

      # An amplitude envelope (see #env and EnvelopeMethods#amp_env).
      def amp_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        note_envelope(:amp_env, attack, decay, sustain, release, **options)
      end
      alias amp_envelope amp_env

      # An FM index envelope (see #env and EnvelopeMethods#fm_env).
      def fm_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        note_envelope(:fm_env, attack, decay, sustain, release, **options)
      end
      alias fm_envelope fm_env

      # A filter cutoff multiplier envelope (see #env and
      # EnvelopeMethods#filter_env).
      def filter_env(attack = nil, decay = nil, sustain = nil, release = nil, **options)
        note_envelope(:filter_env, attack, decay, sustain, release, **options)
      end
      alias filt_env filter_env
      alias filter_envelope filter_env

      # A Pitch following the held note and pitch bend (a
      # Notes::NotePitch), whose oscillators reset their phase at each
      # note-on (key sync) unless they are #free or #lfo.
      #
      #     play v.hz.saw * v.amp_env
      #     play v.hz.bend_range(12.st).square.free * v.amp_env
      def hz
        @pitch ||= NotePitch.new(self)
      end
      alias tone hz
      alias pitch hz

      # A filter cutoff in Hz following the notes (a Notes::Cutoff), for
      # GraphNode#filter's +cutoff:+: +base+ (Hz, a Pitch, or a node) ×
      # brightness (CC 74, ±2 octaves around 64; GM, on unless +gm: false+
      # or `.gm(false)`) × +env+ (a cutoff multiplier such as #filt_env; by
      # default filt_env(0, 0.4, 0.3, 0.3) with a depth of 2 octaves; false
      # for none) × key tracking 2 ** ((note − 60) / 12 × +keytrack+) (0.5
      # by default: half an octave per octave).
      #
      #     play v.hz.saw.filter(:lowpass, cutoff: v.cutoff(800), quality: v.quality(4)) * v.amp_env
      #     v.cutoff(300, env: v.filt_env(0.01, 1, 0.2, 0.5, depth: 4), keytrack: 1)
      def cutoff(base, env: nil, keytrack: 0.5, gm: true)
        base = base.constant? ? base.frequency : base.freq if base.is_a?(MB::Sound::Pitch)
        own = env.nil?
        env = filt_env(0, 0.4, 0.3, 0.3, gm: gm) if own
        env = nil if env == false

        c = Cutoff.new(base, number: number, keytrack: keytrack, env: env, brightness: -> { brightness }, sample_rate: @sample_rate)
        c.own_env! if own
        c.gm(gm)
      end

      # A filter quality following resonance (a Notes::Quality), for
      # GraphNode#filter's +quality:+: +q+ (a number or node) × CC 71
      # (x0.5 at 0, x1 at 64, x4 at 127, exponential; GM, on unless +gm:
      # false+ or `.gm(false)`).
      def quality(q = 1.0, gm: true)
        Quality.new(q, resonance: -> { resonance }, sample_rate: @sample_rate).gm(gm)
      end

      # Vibrato in semitones (a node, for pitch offsets; see
      # NotePitch#vibrato): a sine LFO at +rate+ Hz reset at each note-on, ×
      # +depth+ semitones, × a fade-in over +delay+ seconds after each
      # note-on (Notes::FadeIn).  Defaults: rate = #vibrato_rate (CC 76,
      # 5.5 Hz at 64); depth = #mod × 0.5 semitones × #vibrato_depth (CC 77,
      # x1 at 64); delay = #vibrato_delay (CC 78, 0 at 64) when rate and
      # depth are both defaults, else 0.  Numbers, Intervals (depth), and
      # nodes are all accepted.
      def vibrato(rate = nil, depth: nil, delay: nil)
        defaults = rate.nil? && depth.nil?
        rate ||= vibrato_rate
        depth = depth.nil? ? mod * vibrato_depth * 0.5 : (depth.respond_to?(:sample) ? depth : Interval.semitones(depth).to_f)
        delay ||= defaults ? vibrato_delay : 0

        lfo = MB::Sound::Tone.new(frequency: rate, sample_rate: @sample_rate).lfo.reset(trigger)
        parts = [lfo, depth]
        parts << FadeIn.new(@stream, delay: delay, notes: self, sample_rate: @sample_rate) unless delay == 0
        GraphNode::Multiplier.new(parts, sample_rate: @sample_rate).named('vibrato')
      end

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

      # True when no note is held and every envelope made through this
      # instance (see #env, #register) is idle, so a voice allocator can
      # reuse the voice.  Held notes are known from the note nodes in use
      # (#gate, #number, ...; see #held?), so a voice with only a gate is
      # busy while its note is held.  True with no envelopes and no note
      # nodes.
      def idle?
        !held? && @envelopes.all?(&:idle?)
      end

      # True if any note node made by this instance (#gate, #number,
      # #velocity, #lift, ...) has read a note-on whose note-off it hasn't
      # read yet.  False when there are no note nodes.
      def held?
        @nodes.each_value.any? { |ref|
          node = live(ref)
          node.is_a?(NoteNode) && node.held?
        }
      end

      # The highest current level of the envelopes made through this
      # instance (see #env), or 0 with none; e.g. for the :quietest steal
      # policy (MIDI::Allocator::Lane#level_check).
      def level
        @envelopes.map { |e| e.respond_to?(:level) ? e.level.to_f.abs : 0.0 }.max || 0.0
      end

      # True once the stream's source has ended and every reader has read
      # every event.
      def ended?
        @stream.ended?
      end

      def to_s
        "Notes (#{@stream})"
      end

      # The MIDI::Stream this instance reads, for MIDI::Stream.for, so a
      # Notes can be given wherever a MIDI source is taken (e.g.
      # `Synth.new(midi) { |v| ... }`).
      def to_midi_stream
        @stream
      end

      # A polyphonic MB::Sound::Synth playing this instance's stream (see
      # Synth.new for the options and the block), for console and script
      # code that has a mono Notes (`midi`) and wants voices.
      #
      #     play midi.synth(voices: 6) { |v| v.hz.saw * v.amp_env }
      def synth(**options, &block)
        Synth.new(@stream, **options, &block)
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

      # Makes and registers a NoteEnvelope from an Envelope preset (see
      # #env).
      def note_envelope(preset, attack, decay, sustain, release, lift: false, gm: true, **options)
        lift = case lift
               when true then self.lift
               when false, nil then nil
               else lift
               end

        inputs = { gate: gate, trigger: trigger, velocity: velocity, choke: choke, lift: lift }.compact
        register(NoteEnvelope.preset(
          preset, attack, decay, sustain, release,
          notes: self, gm: gm, sample_rate: @sample_rate, **inputs, **options
        ))
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
require_relative 'notes/fade_in'
require_relative 'notes/glide'
require_relative 'notes/note_envelope'
require_relative 'notes/note_pitch'
require_relative 'notes/filter_nodes'
