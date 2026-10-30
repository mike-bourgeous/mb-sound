module MB
  module Sound
    # Console methods for arranging and performing a live set (see
    # Arrangement and design/notes/arrangement.md): tracks, scenes, mutes
    # and solos, undo, and the take.  MB::Sound extends itself with this
    # module.
    #
    # Example (bin/sound.rb):
    #     bass_a = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
    #     track(:bass, q: 1) { |c| c.tone.saw.lp4(600, resonance: 0.4) * c.amp_env }
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
      # `nudge: 6.ms` pulls a backbeat late).  +send:+ sends it to buses
      # (`send: { verb: -12.db }`) and +to:+ plays it into a bus instead of
      # the master (see BusMethods).  +clock:+ plays its clips on a clock
      # (`track :bowl, clock: :tide do |c| ... end`; see MB::Sound::Clock).
      # Also available as #define_track.
      # +trigger: true+ makes it a trigger track, heard only by sidechain readers
      # (see SidechainMethods#sidechain).
      #
      # A library instrument plays the track's clips (library-instruments-1):
      # an Entry or a preset's name, optionally with the clip it plays
      # (either order), e.g. `track :bass, L.inst.dnb.dnb_reese`, `track
      # :bass, :dnb_reese`, `track :bass, riff, :dnb_reese` (then `bg :bass,
      # riff` or a scene plays it).  The same as `track(:bass) { |clip|
      # preset :dnb_reese, midi: clip }`.  Giving a playing track another
      # instrument builds it again at its launch point (one undo step).
      # Resonator effects play as struck instruments (`track :bells,
      # L.fx.bell` is L.inst.bell); other effects raise with where they go.
      def track(name, *values, q: nil, fade: nil, lead: nil, nudge: nil, lead_max: nil, to: nil, send: nil, clock: nil, trigger: false, &patch)
        Session.current.arrangement.track(name, *values, q: q, fade: fade, lead: lead, nudge: nudge, lead_max: lead_max, to: to, send: send, clock: clock, trigger: trigger, &patch)
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
      # lands.  Also available as #launch_scene.  With no name, starts
      # playback (see TransportMethods#start).
      #
      # Typed at the console while a flow plays, `go` seeks within the flow
      # (maintainer, 2026-10-18: "Seek within the flow"; `go :outro` used
      # to land and then the flow's next scenes took over): the flow jumps
      # to the section that plays the scene (Form::Playback
      # #section_for_scene: the next one forward, else the nearest behind),
      # a :seek change at the scene's launch point, and plays on from
      # there.  +section:+ picks the section by name when several play the
      # scene (`go :drop, section: :drop2`).  When no section plays it, the
      # scene launches and the flow ends where it lands ("you're driving";
      # `start` plays the flow again), and it says so.
      def go(name = nil, section: nil, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        return start(at: point) if name.nil?

        arr = Session.current.arrangement
        pb = arr.playback
        console = pb && !pb.ended? && Session.context&.time.nil?
        if section
          return MB::Sound.live_error(ArgumentError.new("go #{name.inspect}, section: #{section.inspect}: no flow is playing")) unless pb && !pb.ended?
          choices = pb.sections_for_scene(name)
          unless choices.include?(section)
            return MB::Sound.live_error(ArgumentError.new(
              "go #{name.inspect}, section: #{section.inspect}: sections playing #{name.inspect}: #{choices.empty? ? 'none' : choices.map(&:inspect).join(', ')}#{Form.suggest(section, choices)}"
            ))
          end
        end
        if console && (section ||= pb.section_for_scene(name))
          sc = arr.scenes[name]
          point = LaunchPoint.on(sc&.q || arr.quant || :bar) unless point.given?
          entry = seek(section, at: point)
          others = pb.sections_for_scene(name) - [section]
          also = others.empty? ? '' : "; also #{others.map(&:inspect).join(', ')}: go #{name.inspect}, section: #{others.first.inspect}"
          puts "\e[2mgo #{name.inspect}: the flow seeks to its section #{section.inspect} (#{entry.respond_to?(:lands) ? entry.lands : 'queued'}) and plays on from there#{also}\e[0m" if entry
          return entry
        end

        entry = arr.go(name, at: point, fade: fade)
        if console && entry.respond_to?(:lands) && entry.lands
          at = pb.end_at(entry.lands.pos)
          puts "\e[2mgo #{name.inspect}: no section of the flow plays it, so the flow ends at #{at}; you're driving (start plays the flow again)\e[0m"
        end
        entry
      end
      alias launch_scene go

      # Plays a clip slot of track +name+ (the clip matrix: see
      # Arrangement::ClipMatrix): +ref+ is a slot index or a clip's name
      # (`.named(:bass_b)`, a capture like :bass_1).  The `bg :bass, clip`
      # path: journaled, one undo step, at the track's launch point or
      # +on:+/+in:+/+at:+.  Returns the journal entry.
      #
      #     launch :bass, :bass_b
      #     launch :bass, 3, on: :beat
      def launch(name, ref, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        Session.current.arrangement.launch(name, ref, at: point, fade: fade)
      end

      # Replaces track +name+'s clip with a transformed copy at its launch
      # point (one change, one undo step; the copy gets a version mark,
      # e.g. :bass_a_v2, then :bass_a_v3, and becomes a slot; what made it
      # shows in the clip detail pane and the undo step's label):
      # `transpose: 2`
      # (an octave is 12), `legato: 0.8`, `swing: 0.6`, `quantize: 1/16r`
      # (or true), or one of :reverse, :halftime (twice as long),
      # :doubletime (half as long), :double (played twice), :half (its
      # first half).  Returns the journal entry.
      #
      #     tweak :bass, transpose: -12
      #     tweak :bass, :reverse, on: :beat
      def tweak(name, op = nil, at: nil, on: nil, in: nil, fade: nil, **opts)
        point = LaunchPoint.of(binding) or return nil
        Session.current.arrangement.tweak(name, op, at: point, fade: fade, **opts)
      end

      # Makes a number in track +name+'s patch turnable (live literals): a
      # new knob, :"bass/resonance" for `lp4: :resonance` (`as:` names it,
      # `range:` ranges it; else the Param names table's range for the
      # param, holding the literal's value), and the patch built again with
      # `knob(:"bass/resonance")` in that argument's place, swapped in at the
      # track's launch point (`on:`, `in:`, `at:`) keeping its routing.
      # The new graph sounds the same at the knob's starting value, and it
      # takes the old one's running state on the swap frame (held notes,
      # phases, envelope levels, filter states; Session::Carry): where every
      # stateful node matched, bit for bit; delays and reverbs start fresh
      # behind a 5 ms crossfade.  +what+ is { method => param } (the
      # DSL method that took the literal: lp4, amp_env, filter, ...; `nth:`
      # which of the patch's calls of it, in the order the patch makes them) or a graph
      # document param's name (a preset's param no knob drives).  One undo
      # step: undo brings the literal (the old patch and graph) back.
      # Returns the swap's journal entry.  The inspector (ui :sound) runs
      # it for a picked param on Enter.
      #
      #     bind :bass, lp4: :resonance           # knob :"bass/resonance"
      #     bind :bass, amp_env: :attack, as: :att
      #     bind :bass, env: :t2                  # env([[1, 0.01], [0.6, 0.3]])'s second time: :"bass/t2"
      #     bind :bass, env: :t2_level            # its level (:t1_curve a segment's curve)
      #     bind :bass, curve: :release           # a chained .curve(release: 30): :"bass/release_curve"
      #     bind :bass, cutoff: :cut              # preset :dnb_reese's param follows knob :cut
      #
      # A track playing a graph document already has its params as knobs
      # (:"bass/cutoff"; Arrangement::TrackKnobs), so `bind :bass, :cutoff`
      # names that knob; `bind :bass, cutoff: :cut` makes the param follow
      # an existing knob instead (one undo step, like a literal's bind).
      def bind(name, what = nil, nth: 0, as: nil, range: nil, at: nil, on: nil, in: nil, fade: nil, **method_param)
        point = LaunchPoint.of(binding) or return nil
        what ||= method_param
        Session.current.arrangement.bind_literal(name, what, nth: nth, as: as, range: range, point: point, fade: fade)
      end

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
        (hint = SidechainMethods.mute_hint(names)) && puts(hint) # (trigger tracks: their level knob)
        strip_command(:mute, names, point, fade: fade)
      end

      # Sets the level of track or player +name+ (its fader: the strip's
      # gain stage, after its fades and before its mute) to +value+: a
      # linear gain (`-6.db`, 0.5, 0 for silence, up to +12 dB), a knob
      # name, or a node to follow; right away with a short glide, at a
      # launch point (+on:+, +in:+, +at:+), or over +over:+ (bars, a
      # Duration, or a Length; shaped by +curve:+, from where it is or
      # +from:+).  The level is the knob :"name/level" (made at unity the
      # first time), so scenes take `bass: -6.db` and `turn :bass, 0.5`
      # works too.  Journaled, undoable, replayed by takes, saved by set
      # documents.  Returns the journal entry.  With only a name, returns
      # the level (a Decibels); with nothing, every level set so far.
      #
      #     level :bass, -6.db
      #     level :pad, 0, over: 8, on: :bar     # an 8-bar fade-out that stays
      def level(name = nil, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, from: nil, smooth: nil)
        session = Session.current
        return session.levels if name.nil?
        name = player_name(name)
        return session.level(name) if value.nil?
        point = LaunchPoint.of(binding) or return nil
        session_command(name, label: "level #{name.inspect}", kind: :turn) { |s, time|
          s.level(name, value, at: point, over: over, curve: curve, from: from, smooth: smooth, start_time: point.given? ? nil : time)
        }
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
