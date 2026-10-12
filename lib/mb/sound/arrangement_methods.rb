module MB
  module Sound
    # Console methods for arranging and performing a live set (see
    # Arrangement and design/notes/arrangement.md): tracks, scenes, mutes
    # and solos, undo, and the take.  MB::Sound extends itself with this
    # module.
    #
    # Example (bin/sound.rb):
    #     bass_a = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
    #     track(:bass, q: 1) { |c| c.tone.ramp.lp4(600, resonance: 0.4) * c.amp_env }
    #     track :pad, 220.hz.triangle.at(-18.db)
    #     scene :intro, pad: :on
    #     scene :verse, pad: :on, bass: bass_a
    #     go :intro
    #     go :verse          # => scene :verse lands 3:1 (queued)
    #     mute :pad          # now, with a 5 ms declick
    #     unmute :pad, on: :bar
    #     go :drop, at: bar(33)   # or in: 2.bars, on: 4 (bars), on: :beat
    #     solo :bass; solo   # solo, then clear solos
    #     undo               # the last change, at the next bar
    #     take.save          # a replay script of everything played
    module ArrangementMethods
      # Defines a track (see Arrangement#track): a named player that
      # remembers its patch (a block building a graph from a clip) or graph,
      # its clip, and its launch quantization +q:+.  `bg :name, clip` and
      # scenes play clips on it.  +lead:+ plays it early (bars, a Duration
      # or Length, or :attack for its amp envelope's attack, so slow pads
      # peak on the beat, or `0.5.attack` for a fraction of that
      # attack; capped at 1 bar unless +lead_max:+ says
      # otherwise), +nudge:+ moves its notes by a fixed time (e.g.
      # `nudge: 6.ms` pulls a backbeat late).  Also available as
      # #define_track.
      def track(name, graph = nil, q: nil, fade: nil, lead: nil, nudge: nil, lead_max: nil, &patch)
        Session.current.arrangement.track(name, graph, q: q, fade: fade, lead: lead, nudge: nudge, lead_max: lead_max, &patch)
      end
      alias define_track track

      # Lists the tracks: name => "q:1 bass_a (playing)".
      def tracks
        Session.current.arrangement.track_info
      end

      # Defines a scene (see Arrangement#scene): the state of every track,
      # e.g. `scene :verse, pad: :on, bass: bass_a, drums: beat`.  Also
      # available as #define_scene.
      def scene(name, q: nil, fade: nil, others: :stop, **values, &block)
        Session.current.arrangement.scene(name, q: q, fade: fade, others: others, **values, &block)
      end
      alias define_scene scene

      # Lists the scenes, marking the one launched last.
      def scenes
        Session.current.arrangement.scene_info
      end

      # Launches a scene at its launch point (+on:+, +in:+, or +at:+
      # overrides it; see LaunchPoint and Arrangement#go).  Returns the journal entry, which says where it
      # lands.  Also available as #launch_scene.
      def go(name, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        Session.current.arrangement.go(name, at: point, fade: fade)
      end
      alias launch_scene go

      # With an argument, sets the set-wide launch quantization (an
      # alignment like +on:+: a number of bars, :beat, :bar, :clip, :now, or
      # a Duration).  Returns it.
      def quant(q = nil)
        arrangement = Session.current.arrangement
        arrangement.quant = q unless q.nil?
        arrangement.quant
      end

      # Mutes background players or tracks (or mute groups; see #mutes):
      # right away with a 5 ms declick, or at a launch point (+on:+, +in:+,
      # +at:+; see LaunchPoint) over +fade:+ bars.  Muted players sleep
      # (cost no CPU) and come back in time with the timeline.  Returns the
      # change's journal entry (an Array for several names).
      def mute(*names, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        strip_command(:mute, names, point, fade: fade)
      end

      # Unmutes players (every muted player if none are named).  See #mute.
      def unmute(*names, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        strip_command(:unmute, names, point, fade: fade)
      end

      # Solos players: while any player is soloed, the others are silent
      # (and sleep).  With no names, clears every solo.  See #mute.
      def solo(*names, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        strip_command(:solo, names, point, fade: fade)
      end

      # Clears the solo of the named players (every solo if none are named).
      def unsolo(*names, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        strip_command(:unsolo, names, point, fade: fade)
      end

      # With a group name and player names, defines a mute group that
      # #mute, #unmute, #solo, and #unsolo accept (`mutes :breakdown,
      # :drums, :bass`, then `mute :breakdown`).  With no arguments, shows
      # what is muted and soloed and the groups.  Also available as
      # #mute_group.
      def mutes(group = nil, *names)
        session = Session.current
        return session.strip_info if group.nil?
        session.mute_group(group, *names)
      end
      alias mute_group mutes

      # Undoes the last change (a command, scene launch, mute, ...; or the
      # last +count+) by launching the state from before it, at the next bar
      # by default (+on: :now+ for right away; +on:+, +in:+, and +at:+ as in
      # LaunchPoint).  Changes that haven't landed
      # yet are cancelled instead.  Undo is itself undoable with #redo!.
      # Returns what was undone and where it lands.  Also available as
      # #undo_change.
      def undo(count = 1, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        steps = Session.current.undo(count, at: point)
        steps && (steps.length == 1 ? steps.first : steps)
      end
      alias undo_change undo

      # Redoes the last undone change (see #undo).  (`redo` is a Ruby
      # keyword.)  Also available as #redo_change.
      def redo!(count = 1, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        steps = Session.current.redo(count, at: point)
        steps && (steps.length == 1 ? steps.first : steps)
      end
      alias redo_change redo!

      # Lists the changes that #undo can undo, oldest first, with where
      # each landed.  (`history` is a Pry command.)
      def changes
        Session.current.undo_steps.each_with_index.map { |s, i| "#{i + 1}. #{s}" }
      end

      # The console's take (see Take): an always-on log of what was typed
      # and when each change landed; `take.save` writes a replay script.
      def take
        Take.current
      end

      private

      # Runs a mute/solo command through #session_command (so it lands at a
      # scheduled block's time inside one, and is one undo step).
      def strip_command(kind, names, point, fade:)
        names = names.flatten.map { |n| player_name(n) }
        label = "#{kind} #{names.map(&:inspect).join(', ')}".strip
        value = session_command(names, label: label) { |session, time|
          session.public_send(kind, *names, at: point, fade: fade, start_time: point.given? ? nil : time)
        }
        return value unless value.is_a?(Array) && value.all?(Session::Changes::Change)

        session = Session.current
        entries = value.map { |c| session.journal[c.seq] }
        entries.length == 1 ? entries.first : entries
      end
    end
  end
end
