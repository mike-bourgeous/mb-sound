module MB
  module Sound
    # Console methods for the CUE route (see Session::Cue and
    # design/notes/cue.md): hear a part in the headphones, in time with the
    # set, before launching it to MAIN.  MB::Sound extends itself with this
    # module.
    #
    # Example (bin/sound.rb, with CUE_OUTPUT=ports and a 4-channel output,
    # or `cue_output :split` on 2 channels):
    #     cue :acid, seq(A1, A2, C2, A1).n16.loop.tone.ramp.lp4(900) * 0.3   # in the phones only
    #     launch :acid, on: :bar         # to MAIN on the next bar: same graph, no restart
    #     cue :bass, bass_b              # a track's patch on another clip, on CUE
    #     launch :bass, fade: 1.beat     # at the track's q:, crossfading the old clip out
    #     cue :drums                     # pre-listen a playing part (MAIN untouched)
    #     uncue                          # ends every cue
    #     turn :phones, -6.db; turn :cue_mix, 0.5   # phones level, CUE/MAIN blend
    module CueMethods
      # Plays +sound+ on CUE (the headphones; see #cue_output) as player
      # :"name/cue", in time with the set, without touching MAIN; #launch
      # brings it to MAIN.  For a track with a patch, +sound+ may be a Clip
      # or Kit, a clip slot (index or name), or nil for the track's clip.
      # Without a sound, a playing player (or a track playing its clip) is
      # pre-listened: added to CUE, MAIN untouched (#uncue ends it).  A
      # scene name cues every track whose clip it would change; `launch
      # :scene` then launches the scene with those graphs taking over.
      # Starts right away (clips follow the timeline, so it is in time) or
      # at a launch point (+on:+, +in:+, +at:+), fading in over +fade:+
      # bars.
      # Journaled and undoable.  Returns the journal entry.
      def cue(name, sound = nil, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        track = session.arrangement.tracks[name]
        scene = !track && sound.nil? && !session.playing_after_queue?(name) && session.arrangement.scenes.key?(name)
        clipish = sound.nil? || sound.is_a?(Sequence::Clip) || sound.is_a?(Sequence::Kit) || sound.is_a?(Symbol) || sound.is_a?(Integer)

        cue_command("cue #{name.inspect}") { |s, time|
          at = point.given? ? point : (time ? LaunchPoint.on(:now) : nil)
          if scene
            s.arrangement.cue_scene(name, at: at, fade: fade)
          elsif track && clipish
            s.arrangement.cue(name, sound, at: at, fade: fade)
          elsif sound.nil?
            unless s.playing_after_queue?(name)
              next MB::Sound.live_error(ArgumentError.new("Nothing plays as #{name.inspect} to pre-listen; cue a sound with `cue #{name.inspect}, sound`"))
            end
            s.pfl(name, true, time: s.send(:launch_time, at, [], default: nil))
          else
            s.cue_player(name, sound, at: at, fade: fade)
          end
        }
      end

      # Ends the CUE of the named players (all if none): stops their cue
      # players with a declick (or over +fade:+ bars) and ends their
      # pre-listens, right away or at a launch point.  Returns the journal
      # entries.
      def uncue(*names, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        cue_command("uncue #{names.map(&:inspect).join(', ')}".strip) { |s, time|
          time = s.send(:launch_time, point, [], default: nil) if point.given?
          s.uncue(*names, fade: fade, time: time)
        }
      end

      # Without +ref+, launches the cue of +name+ (see #cue) to MAIN at its
      # launch point (a track's +q:+, else the next bar while playing; or
      # +on:+, +in:+, +at:+): the players named +name+ stop there and the
      # cue player becomes +name+, the same graph carrying on, crossfading
      # from CUE to MAIN over +fade:+ bars (a declick by default).  With
      # +ref+, plays a clip slot of track +name+ (see
      # ArrangementMethods#launch).  Returns the journal entry.
      #
      #     launch :acid                 # the cue
      #     launch :bass, :bass_b        # a clip slot
      def launch(name, ref = nil, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        return super(name, ref, at: point, fade: fade) unless ref.nil?

        cue_command("launch #{name.inspect}") { |s, time|
          at = point.given? ? point : (time ? LaunchPoint.on(:now) : nil)
          if s.arrangement.tracks[name]
            s.arrangement.launch_cue(name, at: at, fade: fade)
          elsif !s.cued?(name) && s.arrangement.scenes.key?(name)
            s.arrangement.launch_cued_scene(name, at: at, fade: fade)
          else
            s.launch_cue(name, time: s.send(:launch_time, at, []), fade: fade)
          end
        }
      end

      # Without arguments, the phones blend now (:cue_mix: 0 CUE only, 1
      # MAIN only).  With +value+, turns :cue_mix there (+over:+ and the
      # other options are #turn's); +save: true+ also keeps it as your
      # starting blend in new sessions (a per-user preference next to the
      # listening level; see Session::Cue::Prefs).  Returns the knob's
      # journal entry, or the value.
      #
      #     cue_mix 0.3, save: true
      def cue_mix(value = nil, save: false, **turn)
        session = Session.current
        k = session.cue_knobs[1]
        return k.value if value.nil?
        Session::Cue::Prefs.save_cue_mix(value) if save
        MB::Sound.turn(k.name, value, **turn)
      end

      # What plays on CUE: name => 'cue: description' or 'pfl'.
      def cues
        Session.current.cue_info
      end

      # With a mode, sets where CUE goes (see Session::Cue#cue_output=):
      # :auto (channels 3-4 when the output has them), :ports, :split (2
      # channels: MAIN mono left, phones mono right), :phones (the phones mix
      # on both), :off.  Returns the mode.
      def cue_output(mode = nil)
        session = Session.current
        mode.nil? ? session.cue_output : (session.cue_output = mode)
      end

      private

      # Runs a cue command as one undo step (see PlaybackMethods#session_command)
      # and returns the journal entries of its changes (one entry, or an
      # Array), else the block's value.
      def cue_command(label, &block)
        context = Session.context
        session = Session.current
        time = context&.[](:time)
        if context&.[](:batch)
          context[:batch] << -> { block.call(session, time) }
          return nil
        end

        value, changes = session.command(label) { block.call(session, time) }
        return value if value.is_a?(Session::Journal::Entry) # (a scene launch: its entry)
        entries = (changes || []).map { |c| session.journal[c.seq] }
        return value if entries.empty?
        entries.length == 1 ? entries.first : entries
      end
    end
  end
end
