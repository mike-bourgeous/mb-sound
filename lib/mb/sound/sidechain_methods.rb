module MB
  module Sound
    # Console methods for trigger tracks (see design/notes/dynamics.md,
    # "Trigger tracks"): a sidechain line that duckers and compressors read but
    # nobody hears.  MB::Sound extends itself with this module.
    #
    # Maintainer (2026-10-18): "Duck needs to key off the kick or a
    # dedicated non-sounding line of closed hihats or impulses (gives more
    # control when the kick envelope doesn't trigger the ducker in the
    # desired way)."
    #
    # Example (bin/sound.rb):
    #     sidechain :pump, grid(16, 'x...x...x...x.x.').loop   # a gate on each hit (alias pump)
    #     bg :pad, pad.duck(:pump, amount: -12.db)
    #     sidechain :pump, grid(16, 'x.x.x.x.').loop, shape: env(0, 0.08)  # a shaped key per hit
    #     sidechain(:hats, hat_line) { |c| tr808(c) }         # a sounding patch, never heard
    #     bass.compress(sidechain: :pump, threshold: -30.db)
    #     master { |mix| mix.duck(:pump, amount: -3.db) }
    #     level :pump, 0                                      # the pump off (its level)
    #     sidechains                                          # lists them
    #
    # A trigger track is an Arrangement track (Session::Buses#route with
    # +trigger: true+): scenes give it clips, `launch`, `swap`, `stop`, undo,
    # takes, and set documents treat it like any track, and it shares the
    # track namespace.  Its sound goes nowhere: not the master, buses,
    # sends, stems, CUE, or recordings of the mix; readers (`duck(:pump)`,
    # `bus(:pump)`, `compress(sidechain: :pump)`) hear it on the exact
    # sample at any buffer size, after its fades and before its mute, like
    # any sidechain source, times its level (the track's fader, the knob
    # :"pump/level" like every track's; Session::Faders), which the track's
    # name stands for where a knob is meant (Session::Knobs#control_name):
    # `level :pump, 0` (or `turn :pump, 0`) stops the pump, journaled and
    # undoable, and scenes and sections take `pump: 0` (a number: the
    # level; a clip: the line) and `pump: 1`.
    # Mute doesn't (readers hear sources before their mute), so `mute
    # :pump` prints a hint.
    module SidechainMethods
      # Shape names for #sidechain's +shape:+ besides envelopes.
      SHAPES = [:gate, :impulse].freeze

      # Envelope constructors a +shape:+ may come from (each is also a Clip
      # method that wires the envelope to the clip's notes).
      ENVELOPES = [:env, :amp_env, :fm_env, :filter_env].freeze

      # Defines trigger track +name+ (see the module comment) and, given a
      # +source+ (a Clip, Seq, or grid Kit), plays it there like `bg :name,
      # clip` (at the track's +q:+ or the launch point +on:+/+in:+/+at:+;
      # returns that journal entry, else the name).
      #
      # The key signal is +shape:+ per hit, starting on the exact note-on
      # sample: :gate (default; the note's velocity while it is held, so
      # an accent keys harder and a longer note holds the duck longer),
      # :impulse (one sample at the velocity: pair it with `attack: 0` on
      # the duck, since one sample barely moves a 1 ms attack), or an
      # envelope made by `env`, `amp_env`, `fm_env`, or `filter_env`
      # (`shape: env(0, 0.08)`; played by each note: gated by its length,
      # scaled by its velocity).
      # Or give a block building the key from the clip like a track patch,
      # e.g. closed hats played through a drum machine, never heard:
      #
      #     sidechain(:hats, hats) { |c| tr808(c) }
      #
      # +q:+, +fade:+, and +nudge:+ are as for tracks (a nudge moves the
      # key: `nudge: -5.ms` ducks just before the beat).  Also available as
      # #pump, #trigger_track, and #trigger_line (`key` is the session key).
      #
      # Its level (Session::Faders; default 1): `level :name, 0` stops the
      # pump (the trigger then never reaches a duck's
      # threshold), or `stop :name`.
      def sidechain(name, source = nil, shape: nil, q: nil, fade: nil, nudge: nil, at: nil, on: nil, in: nil, &patch)
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, 'Give a trigger track a shape: or a patch block, not both' if patch && shape
        raise ArgumentError, "Trigger track names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)

        patch_given = !patch.nil?
        patch ||= SidechainMethods.trigger_patch(shape)
        arr = Session.current.arrangement
        arr.track(name, q: q, fade: fade, nudge: nudge, trigger: true, &patch) or return nil
        Session.current.note_trigger_shape(name, patch_given ? nil : (shape.is_a?(Symbol) ? shape : (shape.nil? ? :gate : :envelope)))
        return name if source.nil?
        arr.play(name, source, at: point, fade: fade)
      end
      alias pump sidechain
      alias trigger_track sidechain
      alias trigger_line sidechain

      # Lists the trigger tracks: name => "q:1 pump (playing) read by pad, bass".
      def sidechains
        s = Session.current
        info = s.arrangement.track_info
        readers = s.bus_readers_of
        s.trigger_tracks.to_h { |n|
          r = readers[n]
          [n, "#{info[n]}#{r && !r.empty? ? " read by #{r.join(', ')}" : ' (nothing reads it)'}"]
        }
      end
      alias pumps sidechains
      alias trigger_tracks sidechains
      alias trigger_lines sidechains

      # Warns once per call site when a duck with an attack above 0 reads
      # trigger track +name+ defined with `shape: :impulse` (one sample
      # barely moves a smoothed gain: -0.29 dB of -12 dB at a 1 ms attack).
      # Called by DynamicsMethods#duck.
      def self.check_impulse_duck(name, attack)
        s = Session.existing or return
        return unless s.trigger_shape(name) == :impulse
        return if attack.is_a?(Numeric) && attack <= 0
        Decibels.warn_once(:impulse_trigger, "duck(#{name.inspect}) reads #{name.inspect}'s one-sample impulses with attack: #{attack.inspect}, which barely ducks; give the duck attack: 0, or the trigger track shape: :gate (the default)")
      end

      # The one-line hint `mute` prints for trigger tracks among +names+
      # (mute doesn't stop a pump), or nil.
      def self.mute_hint(names)
        s = Session.existing or return nil
        keys = names.flatten.select { |n| n.is_a?(Symbol) && s.trigger_track?(n) }
        return nil if keys.empty?
        n = keys.first
        "#{keys.map(&:inspect).join(', ')} #{keys.length == 1 ? 'is a trigger track' : 'are trigger tracks'}: mute doesn't stop a pump (ducks read it before its mute); level #{n.inspect}, 0 or stop #{n.inspect}"
      end

      # The patch block for +shape+ (see #sidechain).
      def self.trigger_patch(shape)
        case shape
        when nil, :gate
          proc { |clip|
            n = SidechainMethods.trigger_clip(clip).notes
            n.gate * n.velocity
          }
        when :impulse, :impulses
          proc { |clip| SidechainMethods.trigger_clip(clip).trigger }
        when Envelope
          call = GraphNode::Recipe.record_of(shape)
          rec = call&.call
          unless rec && rec.receiver == MB::Sound && ENVELOPES.include?(rec.name) && call.config.nil?
            raise ArgumentError, "shape: takes an envelope as made by #{ENVELOPES.join(', ')} (e.g. env(0, 0.08)), :gate, :impulse, or a patch block instead (sidechain(:pump, clip) { |c| c.env(0, 0.08) })"
          end
          if (rec.kwargs.keys & %i[gate trigger velocity choke]).any?
            raise ArgumentError, "shape: is played by each key note; its envelope takes no gate:, trigger:, velocity:, or choke: of its own"
          end
          name, args, kwargs = rec.name, rec.args, rec.kwargs
          proc { |clip| SidechainMethods.trigger_clip(clip).public_send(name, *args, **kwargs) }
        else
          raise ArgumentError, "shape: is :gate, :impulse, or an envelope such as env(0, 0.08) (got #{shape.inspect}); a patch block builds anything else"
        end
      end

      # A grid Kit's rows stacked into one clip; Clips as they are.
      def self.trigger_clip(clip)
        clip.is_a?(Sequence::Kit) ? clip.to_clip : clip
      end
    end
  end
end
