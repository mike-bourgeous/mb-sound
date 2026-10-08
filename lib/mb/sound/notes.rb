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
    # node's own sample rate (see Notes::Node); for clips, the samples where
    # the clip's edges fall at the transport's tempo.  Nodes are made once per Notes instance and
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
    # Pedals: note nodes apply the sustain, sostenuto, and soft pedals
    # (MIDI::Stream#sustain; see #note_stream) unless +sustain: false+, as
    # MB::Sound::Synth does.
    #
    # Examples:
    #     v = MB::Sound::Notes.new(seq(C3, E3, G3).n8.loop)
    #     play v.hz.saw * v.gate
    #     v.number.smooth(0.05, reset: v.trigger)
    #
    # MB::Sound::Synth builds one Notes per MIDI::Allocator lane; the output
    # methods of Sequence::Clip (clip.env, clip.tone, ...) are the nodes of a
    # Notes on the clip (Clip#notes); the console's `midi` (MidiMethods#midi)
    # and synth scripts' block argument are Notes on live or file MIDI.
    class Notes
      include ModMethods

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

      # CC 71 (GM2 "resonance", the same controller as #resonance) as a
      # position -1..1 around the knob's center, for #reso: 0 at raw 0, the
      # base amount at 64, 1 at 127.
      RESONANCE_AMOUNT = MIDI::ControlSpec.new(
        number: 71, name: 'Resonance', range: -1.0..1.0, center: 0, default: 64,
        description: '4-pole resonance: 0, the base at 64, 1 (Notes#reso)'
      ).freeze

      class << self
        # Whether Notes nodes and envelopes take their fast paths for
        # buffers without events (constant frozen buffers, envelope times
        # as numbers; see Notes::Node#sample).  On unless the environment
        # sets MB_SOUND_NOTES_FAST=0.  The output is the same either way;
        # specs compare the two.
        attr_accessor :fast_paths

        # The default smoothing time of controller nodes (#cc, the GM-named
        # controls, #pressure, #poly_pressure, #aftertouch; seconds or a
        # Length, or false for exact steps), CONTROL_SMOOTHING unless
        # changed.  Applies to nodes made afterwards.  See Notes::Smoother.
        attr_accessor :control_smoothing

        # The default smoothing time of pitch bend (#bend,
        # #bend_semitones, and so every #hz and #freq), BEND_SMOOTHING
        # unless changed.  See .control_smoothing.
        attr_accessor :bend_smoothing

        # Resolves a node's +:smooth+ option: nil or true give +default+,
        # false or 0 give nil (no smoothing), else a time (seconds or a
        # Length) as is.
        def smoothing(smooth, default)
          smooth = default if smooth.nil? || smooth == true
          return nil if smooth.nil? || smooth == false || smooth == 0

          unless smooth.is_a?(Length) || (smooth.is_a?(Numeric) && smooth > 0)
            raise ArgumentError, "Smoothing must be a time (seconds or a Length), true, or false (got #{smooth.inspect})"
          end

          smooth
        end
      end
      self.fast_paths = ENV['MB_SOUND_NOTES_FAST'] != '0'

      # The default smoothing time of controllers and pressure (see
      # .control_smoothing): each MIDI value step becomes a 10 ms S-shaped
      # transition (Notes::Smoother), delayed by half that.
      CONTROL_SMOOTHING = 0.010

      # The default smoothing time of pitch bend (see .bend_smoothing):
      # shorter than CONTROL_SMOOTHING, since bend steps mostly come fast
      # (14-bit wheels) and pitch steps zipper less than level or cutoff
      # steps, while bends should feel immediate.
      BEND_SMOOTHING = 0.005

      self.control_smoothing = CONTROL_SMOOTHING
      self.bend_smoothing = BEND_SMOOTHING

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

      # The MIDI::Stream this instance was given (before the sustain pedal
      # transform; see #note_stream).  Controllers read it (or the stream
      # it was split from; see .control_stream), synths built from this
      # instance read it (see #to_midi_stream), and its #source is the
      # MIDI source (e.g. a LiveSource or FileSource).
      attr_reader :stream

      # The sample rate of nodes made from now on (graphs change it as
      # usual; see GraphNode::SampleRateHelper).
      attr_reader :sample_rate

      # Creates a Notes instance reading +source+ (see the class
      # description).  Note nodes read it through the sustain, sostenuto,
      # and soft pedals (MIDI::Stream#sustain) unless +sustain: false+, as
      # MB::Sound::Synth does; Synth lanes (already pedaled) and clip
      # outputs (clips have no pedals) pass false.
      def initialize(source, sustain: true, sample_rate: 48000)
        @stream = MIDI::Stream.for(source)
        @sustain = !!sustain
        @note_stream = nil
        @control_stream = Notes.control_stream(@stream)
        @sample_rate = sample_rate.to_f
        @nodes = {}
        @envelopes = []
        @quiet_check = nil
        @level_check = nil
      end

      # A Proc (or anything with #call) returning true once the output of
      # the graph built on this instance has gone quiet, or nil (the
      # default) to ignore the output.  Synth sets one per lane, so voices
      # without envelopes (e.g. resonant filter pings) stay busy, and their
      # gate and trigger keep going after a MIDI file ends, until they have
      # rung out (see #idle?).
      attr_accessor :quiet_check

      # A Proc (or anything with #call) returning the measured peak level
      # of the output of the graph built on this instance, or nil (the
      # default) to use the envelope levels (see #level).  Synth sets one
      # per lane, so the :quietest steal policy also works for voices
      # without envelopes.
      attr_accessor :level_check

      # The stream read by channel-wide nodes (see .control_stream).
      attr_reader :control_stream

      # True if note nodes apply the sustain pedals (see #initialize).
      def sustain?
        @sustain
      end

      # The stream note nodes read: #stream through the sustain pedal
      # transform (MIDI::Stream#sustain) with +sustain: true+, else #stream.
      #
      # The pedaled stream is made when a note node first needs it, and
      # held only by the nodes reading it (this instance keeps a weak
      # reference), so a Notes used only for controllers or as a synth's
      # source (e.g. the console's `midi`) never leaves an unread transform
      # holding the input's events back (late readers of a stream start at
      # its slowest reader).
      def note_stream
        return @stream unless @sustain

        s = live(@note_stream)
        return s if s

        s = @stream.sustain
        @note_stream = WeakRef.new(s)
        s
      end

      # 1 while any note is held, else 0 (a Notes::Gate).
      def gate
        memo(:gate) { Gate.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end

      # A single-sample impulse at every note-on, valued at its velocity
      # (0..1; a Notes::Trigger).  Inputs that take triggers (Tone#reset,
      # Envelope +:trigger+, #smooth +reset:+) react to its rising edges.
      def trigger
        memo(:trigger) { Trigger.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end

      # The key sync trigger (a Notes::KeyTrigger): #trigger without the
      # note-ons that re-strike a voice whose energy is being added to, so
      # oscillators keep their phase when a ringing note is struck again.
      # A note-on is left out when an envelope made through this instance
      # with +retrigger: :add+ (Envelope's; e.g. Synth's +retrigger: :add+,
      # :ring, :string) is sounding (not idle) when it arrives (see
      # #adding_at?); with only :restart envelopes (the default), or none,
      # it is the same as #trigger.  A mono voice re-struck while its note
      # is held or still ringing counts too, as does a Synth lane re-struck
      # while ringing.
      #
      # Oscillators from #hz key-sync to this (see NotePitch), and so should
      # tones that sync to notes by hand; #trigger keeps every note-on, for
      # envelopes and for tones that must restart at each note:
      #
      #     (v.freq * ratio).tone.reset(v.key_trigger)    # key sync, like v.hz
      #     110.hz.square.reset(v.trigger)                # restarts at every note-on
      def key_trigger
        memo(:key_trigger) { KeyTrigger.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end
      alias key_sync_trigger key_trigger

      # The note number of the newest held note, held after release (a
      # Notes::Number), starting at the source's first note (or C4).
      def number
        memo(:number) { Number.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end
      alias note_number number

      # The velocity (0..1) of the latest note-on (a Notes::Velocity).
      def velocity
        memo(:velocity) { Velocity.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end

      # The release velocity (0..1) of the latest note-off (a Notes::Lift),
      # 64/127 until the first one.
      def lift
        memo(:lift) { Lift.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end
      alias release_velocity lift

      # A single-sample impulse of 1 at every :choke event (see
      # MIDI::Event.choke) and all sound off (CC 120) (a Notes::Choke).
      # Envelopes from this instance release over Envelope::CHOKE_TIME at
      # each one.
      def choke
        memo(:choke) { Choke.new(note_stream, notes: self, sample_rate: @sample_rate) }
      end

      # The frequency in Hz of #number plus pitch bend (MIDI::Event#bend_semitones,
      # with the stream's bend range) through the session Tuning (a
      # Notes::Frequency).
      def freq
        memo(:freq) { Frequency.new(number, offsets: [bend_semitones], sample_rate: @sample_rate) }
      end
      alias frequency freq

      # The Notes::Frequency for NotePitch +settings+ at +sample_rate+,
      # made by the block once and shared by every pitch with the same
      # settings (e.g. each `v.hz.transpose(7)`), so tones on equal pitches
      # read one Frequency node through a Tee.  Default settings at this
      # instance's rate give #freq.  Used by NotePitch#freq.
      def frequency_for(settings, sample_rate)
        return freq if settings == NotePitch::DEFAULTS && sample_rate.to_f == @sample_rate
        memo([:frequency, settings, sample_rate.to_f]) { yield }
      end

      # Pitch bend, -1..1 (a Notes::Bend shared by every Notes instance on
      # the control stream), smoothed over +:smooth+ (default
      # Notes.bend_smoothing; false for exact steps; see Notes::Smoother).
      def bend(smooth: nil)
        shared(smooth_key(:bend, smooth)) { Bend.new(@control_stream, sample_rate: @sample_rate, smooth: smooth) }
      end

      # Pitch bend in semitones (a shared Notes::Bend): with +range+ nil,
      # the stream's bend range (2 semitones unless RPN 0 or
      # MIDI::Stream#bend_range changes it; see MIDI::Event#bend_semitones),
      # or +range+ (an Interval or semitones, e.g. `12.st`) for full bend.
      # Smoothed like #bend.
      def bend_semitones(range = nil, smooth: nil)
        range = range.nil? ? :stream : Interval.semitones(range).to_f
        shared(smooth_key([:bend, range], smooth)) { Bend.new(@control_stream, range: range, sample_rate: @sample_rate, smooth: smooth) }
      end

      # A MIDI controller as a shared Notes::Control node (one per control
      # stream and spec), mapped linearly from raw 0..127 to +range+ (see
      # MIDI::ControlSpec for other mappings; pass a spec to #control),
      # starting at the raw +default+ (0..127).  Each value step glides over
      # +:smooth+ (default Notes.control_smoothing, 10 ms; a time in seconds
      # or a Length, or false for exact steps on the event samples; switch
      # controllers step unless given a time; see Notes::Smoother).
      #
      #     v.cc(1)                        # mod wheel, 0..1
      #     v.cc(16, range: 200..2000)     # general purpose 1 as a cutoff
      #     v.cc(74, smooth: 30.ms)        # a slower glide
      #     v.cc(20, smooth: false)        # exact steps
      def cc(number, range: 0.0..1.0, default: 0, name: nil, description: nil, smooth: nil)
        control(MIDI::ControlSpec.new(number: number, range: range, default: default, name: name, description: description), smooth: smooth)
      end

      # A shared Notes::Control node for a MIDI::ControlSpec (see #cc).
      def control(spec, smooth: nil)
        shared(smooth_key([:cc, spec], smooth)) { Control.new(@control_stream, spec, sample_rate: @sample_rate, smooth: smooth) }
      end

      GM_CONTROLS.each do |name, spec|
        define_method(name) { |smooth: nil| control(spec, smooth: smooth) }
      end
      alias modulation mod
      alias mod_wheel mod
      alias breath_controller breath
      alias foot_controller foot
      alias sound_brightness brightness
      alias timbre resonance

      # A MIDI::ControlMap of the controller nodes in use on this instance's
      # control stream (shared by every Notes instance there, so every lane
      # of a synth), for control lists and ACID XML (`midi.controls` in the
      # console; see MIDI::ControlMap#to_acid_xml).
      def controls
        MIDI::ControlMap.new(self)
      end

      # The MIDI::ControlSpecs of the controller nodes in use on this
      # instance's control stream (CCs, pitch bend, including the bend
      # inside #hz and #freq, and channel pressure), plus the sustain pedals
      # (MIDI::Transform::Sustain::CONTROL_SPECS) while note nodes read
      # through them (see #note_stream), sorted by controller number (see
      # #controls).
      def control_specs
        cache = SHARED[@control_stream] || {}
        specs = cache.values.filter_map { |ref| live(ref) }.grep(ChannelNode).flat_map(&:control_specs)
        specs += MIDI::Transform::Sustain::CONTROL_SPECS if @sustain && live(@note_stream)
        specs << MIDI::ControlSpec.poly_pressure if @nodes.any? { |k, ref| (k == :poly_pressure || (k.is_a?(Array) && k[0] == :poly_pressure)) && live(ref) }
        specs.uniq.sort_by { |s| [*s.key, s.name, s.range.begin] }
      end

      # Channel pressure (aftertouch), 0..1 (a shared Notes::Pressure),
      # smoothed like #cc.  See #aftertouch for either kind of pressure.
      def pressure(smooth: nil)
        shared(smooth_key(:pressure, smooth)) { Pressure.new(@control_stream, sample_rate: @sample_rate, smooth: smooth) }
      end
      alias channel_pressure pressure

      # Polyphonic key pressure (poly aftertouch, MIDI 0xA0), 0..1, of this
      # voice's note: the newest held note's pressure (a
      # Notes::PolyPressure).  In a Synth, each lane gets the pressure of
      # the key it plays (MIDI::Allocator routes it), so every note of a
      # chord follows its own finger.  Smoothed like #cc, except that each
      # note starts at its own pressure at once.
      #
      #     play midi.synth { |v| v.hz.saw.lp4(v.cutoff(400) * (2 ** (v.poly_pressure * 3))) * v.amp_env }
      def poly_pressure(smooth: nil)
        memo(smooth_key(:poly_pressure, smooth)) { PolyPressure.new(note_stream, notes: self, sample_rate: @sample_rate, smooth: smooth) }
      end
      alias key_pressure poly_pressure
      alias poly_aftertouch poly_pressure

      # Aftertouch of either kind, 0..1: the larger of #poly_pressure and
      # channel #pressure (a Notes::Aftertouch), so a patch works with
      # keyboards that send either (the SQ-80 sends one or the other) and
      # doesn't double when one sends both.  (Before poly pressure, this
      # was an alias of #pressure.)  +:smooth+ applies to both (see #cc).
      def aftertouch(smooth: nil)
        memo(smooth_key(:aftertouch, smooth)) { Aftertouch.new(poly_pressure(smooth: smooth), pressure(smooth: smooth), sample_rate: @sample_rate) }
      end

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

      # An SQ-80-style envelope (a NoteEnvelope) from panel values: levels
      # +:l1+, +:l2+, +:l3+ (-63..+63, L3 = sustain), times +:t1+..+:t4+
      # (0..63, the manual's time chart), +:lv+ (velocity to levels, 0..63)
      # with +:lv_curve+ (:linear or :exp), +:t1v+ (velocity shortens T1),
      # +:tk+ (higher keys shorten T2 and T3), +:second_release+ (the T4 "R"
      # pseudo-reverb tail), +:cycle+ (CYC: run every stage, ignoring the
      # key-up), +:loop+ (an extension: repeat from a segment while held),
      # +:restart+ (true: every note starts from 0, the SQ-80's ENV
      # restart mode; Envelope retrigger: :zero),
      # and +:curve+.  See MB::Sound::SQ80.env_options.  Other options are
      # Envelope's (e.g. +:retrigger+, +:octaves+).  Multiply by a depth or
      # feed #mod_sum for bipolar modulation.
      #
      #     amp = v.sq80_env(l1: 63, l2: 50, l3: 40, t1: 0, t2: 30, t3: 40, t4: 30, lv: 40)
      #     wah = v.sq80_env(l1: 63, l2: -20, l3: 10, t1: 10, t2: 20, t3: 20, t4: 25, loop: :t2)
      def sq80_env(lift: false, gm: true, **panel)
        known = SQ80.method(:env_options).parameters.map(&:last) - [:velocity, :key]
        env_opts = panel.slice(*known)
        options = panel.except(*known)
        opts = SQ80.env_options(velocity: velocity, key: number, **env_opts)
        segments = opts.delete(:segments)
        note_envelope(:adsr, segments, nil, nil, nil, lift: lift, gm: gm, gate: !panel[:cycle], **opts, **options)
      end

      # A Pitch following the held note and pitch bend (a
      # Notes::NotePitch), whose oscillators reset their phase at each
      # note-on (key sync, #key_trigger: not at re-strikes that add energy
      # to a sounding voice) unless they are #free or #lfo.
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

      # A 0..1 resonance amount following resonance (CC 71; a
      # Notes::Resonance), for GraphNode#lp4's +resonance:+: +amount+ (a
      # number or node) at 64, falling linearly to 0 at 0 and rising
      # linearly to 1 at 127, so the knob always reaches both ends (GM, on
      # unless +gm: false+ or `.gm(false)`).  #quality is the same control
      # for 2-pole filters (a Q multiplier).  Alias #resonance_amount
      # (#resonance is the raw CC 71 node).
      #
      #     v.hz.saw.lp4(v.cutoff(300), resonance: v.reso(0.6)) * v.amp_env
      def reso(amount = 0.5, gm: true)
        Resonance.new(amount, control: -> { control(RESONANCE_AMOUNT) }, sample_rate: @sample_rate).gm(gm)
      end
      alias resonance_amount reso

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

        lfo(rate, shape: :sine, depth: depth, delay: delay).named('vibrato')
      end

      # LFO shapes for #lfo, with aliases.
      LFO_SHAPES = {
        sine: :sine, sin: :sine,
        triangle: :triangle, tri: :triangle,
        saw: :ramp, ramp: :ramp, sawtooth: :ramp,
        square: :square, sqr: :square,
        noise: :noise, random: :noise, sh: :noise, sample_hold: :noise,
      }.freeze

      # LFO phase modes for #lfo (+:sync+).
      LFO_SYNC = [:key, :free, :random].freeze

      # A per-voice LFO for modulation (SQ-80 style; a Multiplier of a Tone
      # made with Tone#lfo, its depth, and a fade-in):
      #
      # +rate+ - Hz (a number or a node, e.g. following poly pressure), or a
      #          musical length (a Duration such as `1.n8` or `2.bars`: one
      #          cycle per length, following the tempo and locked to the
      #          timeline).
      # +:shape+ - :triangle (default; alias :tri), :saw (rising; :ramp),
      #            :square (:sqr), :sine, or :noise (alias :random, :sh):
      #            a random value held for each cycle (sample and hold; see
      #            GraphNode::SampleHold).  LFO shapes keep exact edges below
      #            15 Hz (Tone#lfo).
      # +:depth+ - Output scale (a number, Interval as semitones, or node;
      #            default 1).
      # +:delay+ - Seconds (or a node) over which the depth fades in after
      #            each note-on (Notes::FadeIn), from +:from+ (a fraction
      #            of the depth, default 0) to the full depth; the SQ-80's
      #            L1 -> L2 depth ramp.
      # +:sync+ - :key (default for Hz rates: restart at phase 0 at each
      #           note-on, the SQ-80's RESET), :free (never restart; tempo
      #           LFOs stay locked to the timeline, the default for
      #           Durations), or :random (a random phase at each note-on).
      # +:wheel+ - Mod wheel depth added to the depth (wheel × this; e.g.
      #            0.5 or `1.st`), the SQ-80's LFO MOD source.
      # +:pressure+ - Aftertouch depth added the same way (#aftertouch:
      #               poly or channel pressure).
      # +:unipolar+ - true for 0..1 instead of -1..1 (the SQ-80's square is
      #               unipolar).
      # +:human+ - Random rate variation, a fraction of the rate (e.g. 0.2),
      #            changing once per cycle (the SQ-80's HUMAN; numeric
      #            rates only).
      # +:seed+ - Seed for the :noise shape, random phases, and :human.
      #
      #     v.hz.transpose(v.lfo(5.5, depth: 0.3, delay: 0.4, wheel: 0.5))   # delayed vibrato
      #     cutoff = v.cutoff(400) * (2 ** v.lfo(1.n8, shape: :square, depth: 1))
      #     v.lfo(v.mod_scale(1, v.poly_pressure => 3.oct), shape: :noise)   # pressure speeds it up
      def lfo(rate = 5.0, shape: :triangle, depth: 1.0, delay: 0, from: 0, sync: nil, wheel: nil, pressure: nil, unipolar: false, human: nil, seed: nil)
        wave = LFO_SHAPES.fetch(shape) { raise ArgumentError, "Unknown LFO shape #{shape.inspect} (#{LFO_SHAPES.keys.join(', ')})" }
        tempo = rate.is_a?(MB::Sound::Sequence::Duration)
        sync ||= tempo ? :free : :key
        raise ArgumentError, "LFO sync must be one of #{LFO_SYNC} (got #{sync.inspect})" unless LFO_SYNC.include?(sync)
        raise ArgumentError, 'human: needs a numeric or node rate' if human && tempo

        depth = Interval.semitones(depth).to_f if depth.is_a?(Interval)
        rate = lfo_human(rate, human, seed) if human && human != 0

        tone = tempo ? rate.lfo : MB::Sound::Tone.new(frequency: rate, sample_rate: @sample_rate).lfo
        tone = case wave
               when :sine then tone
               when :noise then tone.asquare
               else tone.public_send(wave)
               end
        case sync
        when :key then tone.reset(trigger)
        when :random then tone.reset(trigger, to: :random).tap { |t| t.seed = seed if seed }
        end

        src = if wave == :noise
                tone.sample_hold(range: unipolar ? 0.0..1.0 : -1.0..1.0, seed: seed)
              else
                unipolar ? tone.at(0..1) : tone
              end

        depth = lfo_depth(depth, wheel, pressure)
        parts = [src, depth]
        unless delay == 0
          fade = FadeIn.new(note_stream, delay: delay, notes: self, sample_rate: @sample_rate)
          fade = fade * (1.0 - from) + from unless from == 0
          parts << fade
        end
        GraphNode::Multiplier.new(parts, sample_rate: @sample_rate).named('lfo')
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

      # True when no note is held, every envelope made through this
      # instance (see #env, #register) is idle, and the #quiet_check (if
      # any) says the output is quiet, so a voice allocator can reuse the
      # voice.  Held notes are known from the note nodes in use (#gate,
      # #number, ...; see #held?), so a voice with only a gate is busy
      # while its note is held.  True with no envelopes, no note nodes, and
      # no quiet check.
      def idle?
        voice_idle? && quiet?
      end

      # True if the #quiet_check says the output is quiet, or if there is no
      # quiet check.
      def quiet?
        @quiet_check.nil? || !!@quiet_check.call
      end

      # Like #idle?, without the #quiet_check: no note held and every
      # envelope idle.
      def voice_idle?
        !held? && envelopes_idle?
      end

      # True if every envelope made through this instance (see #env,
      # #register) is idle.
      def envelopes_idle?
        @envelopes.all?(&:idle?)
      end

      # True if any envelope made through this instance has +retrigger:
      # :add+ (see Envelope#retrigger).
      def add_envelopes?
        @envelopes.any? { |e| add_envelope?(e) }
      end

      # True if an envelope made through this instance with +retrigger:
      # :add+ was sounding (not idle) at stream time +time+, the start of
      # a buffer (NoteEnvelope#sounding_at?, so the answer doesn't depend
      # on whether the envelopes have rendered that buffer yet), so a
      # note-on there adds energy to a sounding voice instead of starting
      # one (see #key_trigger).
      def adding_at?(time)
        @envelopes.any? { |e|
          add_envelope?(e) && (e.respond_to?(:sounding_at?) ? e.sounding_at?(time) : !e.idle?)
        }
      end

      # True if any note node made by this instance (#gate, #number,
      # #velocity, #lift, ...) has read a note-on whose note-off it hasn't
      # read yet.  False when there are no note nodes.
      def held?
        @nodes.any? { |_, ref|
          node = live(ref)
          node.is_a?(NoteNode) && node.held?
        }
      end

      # The measured peak of the output (see #level_check) if there is a
      # level check, else the highest current level of the envelopes made
      # through this instance (see #env), or 0 with none; e.g. for the
      # :quietest steal policy (MIDI::Allocator::Lane#level_check).
      def level
        return @level_check.call.to_f if @level_check
        @envelopes.map { |e| e.respond_to?(:level) ? e.level.to_f.abs : 0.0 }.max || 0.0
      end

      # True once the stream's source has ended and every reader has read
      # every event.
      def ended?
        (live(@note_stream) || @stream).ended?
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

      # Modulation source names for #mod_sum and #mod_scale (see
      # #mod_source).
      MOD_SOURCES = [
        :velocity, :vel, :velocity_x, :vel_x, :key, :keyboard, :wheel, :mod, :pressure, :channel_pressure,
        :poly_pressure, :key_pressure, :aftertouch, :pedal, :foot, :breath, :bend, :lift, :gate,
      ].freeze

      # The graph node for a modulation source of #mod_sum / #mod_scale
      # (ModMethods): a node or number as is, or a Symbol naming this
      # voice's controls, after the SQ-80's sources:
      # - :velocity (:vel) 0..1, :velocity_x (:vel_x) velocity squared (the
      #   SQ-80's VEL-X, an exponential-feeling curve)
      # - :key (:keyboard): octaves from C4 (note − 60) / 12, so `:key =>
      #   1.oct` in #mod_scale is full key tracking (the SQ-80's KYBD and
      #   KYBD2 are offsets and scales of this)
      # - :wheel (:mod) CC 1, :pedal (:foot) CC 4, :breath CC 2, :bend -1..1
      # - :pressure (:channel_pressure), :poly_pressure (:key_pressure),
      #   :aftertouch (the larger of both)
      # - :lift (release velocity), :gate (1 while held)
      def mod_source(source)
        return super unless source.is_a?(Symbol)

        case source
        when :velocity, :vel then velocity
        when :velocity_x, :vel_x then memo(:velocity_x) { (velocity * velocity).named('velocity²') }
        when :key, :keyboard then memo(:key_octaves) { ((number - 60.0) * (1.0 / 12)).named('key octaves') }
        when :wheel, :mod then mod
        when :pressure, :channel_pressure then pressure
        when :poly_pressure, :key_pressure then poly_pressure
        when :aftertouch then aftertouch
        when :pedal, :foot then foot
        when :breath then breath
        when :bend then bend
        when :lift then lift
        when :gate then gate
        else
          raise ArgumentError, "Unknown modulation source #{source.inspect} (#{MOD_SOURCES.join(', ')})"
        end
      end
      public :mod_source

      # The depth for #lfo: +depth+ plus wheel and aftertouch amounts.
      def lfo_depth(depth, wheel, pressure)
        extra = {}
        extra[mod] = wheel_amount(wheel) if wheel && wheel != 0
        extra[aftertouch] = wheel_amount(pressure) if pressure && pressure != 0
        return depth if extra.empty?

        GraphNode::Mixer.new([[depth, 1.0], *extra.map { |n, a| a.respond_to?(:sample) ? [n * a, 1.0] : [n, a] }], sample_rate: @sample_rate).named('lfo depth')
      end

      # A depth amount: a number, an Interval (semitones), or a node.
      def wheel_amount(amount)
        amount.is_a?(Interval) ? Interval.semitones(amount).to_f : amount
      end

      # +rate+ × (1 + +human+ × a random value held for each cycle of a
      # half-rate square), for #lfo's +:human+.
      def lfo_human(rate, human, seed)
        steps = MB::Sound::Tone.new(frequency: rate.respond_to?(:sample) ? rate * 0.5 : rate * 0.5, sample_rate: @sample_rate).lfo.asquare
        jitter = steps.sample_hold(seed: seed && seed + 1)
        (jitter * human.to_f + 1.0) * rate
      end

      # True if +envelope+ adds re-strikes' energy (see #adding_at?).
      def add_envelope?(envelope)
        envelope.respond_to?(:retrigger) && envelope.retrigger == :add
      end

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
      def note_envelope(preset, attack, decay, sustain, release, lift: false, gm: true, gate: true, **options)
        lift = case lift
               when true then self.lift
               when false, nil then nil
               else lift
               end

        inputs = gate ? envelope_inputs : { trigger: trigger, velocity: velocity, choke: choke }
        inputs = inputs.merge(lift: lift).compact
        register(NoteEnvelope.preset(
          preset, attack, decay, sustain, release,
          notes: self, gm: gm, sample_rate: @sample_rate, **inputs, **options
        ))
      end

      # The gate, trigger, velocity, and choke inputs for a new envelope:
      # with Notes.fast_paths, one EnvelopeInputs node of its own (one
      # reader instead of four shared nodes and their Tees), else #gate,
      # #trigger, #velocity, and #choke (the same samples).
      def envelope_inputs
        return { gate: gate, trigger: trigger, velocity: velocity, choke: choke } unless Notes.fast_paths

        node = memo([:envelope_inputs, @envelopes.length]) { EnvelopeInputs.new(note_stream, notes: self, sample_rate: @sample_rate) }
        { gate: node, trigger: node.trigger, velocity: node.velocity, choke: node.choke }
      end

      # The cache key for a node made with smoothing option +smooth+: +key+
      # for the default (nil or true), else [+key+, :smooth, +smooth+].
      def smooth_key(key, smooth)
        smooth.nil? || smooth == true ? key : [key, :smooth, smooth]
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

require_relative 'notes/smoother'
require_relative 'notes/node'
require_relative 'notes/note_stack'
require_relative 'notes/note_nodes'
require_relative 'notes/channel_nodes'
require_relative 'notes/frequency'
require_relative 'notes/fade_in'
require_relative 'notes/glide'
require_relative 'notes/envelope_inputs'
require_relative 'notes/note_envelope'
require_relative 'notes/note_pitch'
require_relative 'notes/filter_nodes'
require_relative 'notes/poly_pressure'
require_relative 'notes/plan_support'
