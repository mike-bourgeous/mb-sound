module MB
  module Sound
    class Arrangement
      # Build knobs (sound-design-2): a track knob that its patch reads
      # while it builds (GraphNode.build_value: the init voice's sync,
      # Tone#sync's +enabled:+) chooses the graph's structure, so the graph
      # can't follow it.  Turning one rebuilds the tracks that read it at
      # their launch points (`turn :"lead/sync", 1` is a bind-like rebuild:
      # one undo step, journaled, replayed from takes), carrying the
      # running state across where the graphs match (Arrangement::Carry).
      #
      # Only plain values: ramps, follows, gestures, and keyframes of a
      # build knob go through live_error (a structure can't move between
      # two values).  Scenes, snapshots, and MIDI controllers that set a
      # build knob change its value without a rebuild (the next build reads
      # it).
      module BuildKnobs
        # Notes that track +track+'s patch read knob +name+ while building.
        def note_build_knob(track, name)
          @build_knob_lock.synchronize {
            list = (@build_knobs[name] ||= [])
            list << track unless list.include?(track)
          }
        end

        # Forgets that track +track+'s patch read knob +name+ while building
        # (a bind's test build that was refused; LiteralBinding).
        def forget_build_knob(track, name)
          @build_knob_lock.synchronize {
            list = @build_knobs[name] or next
            list.delete(track)
            @build_knobs.delete(name) if list.empty?
          }
        end

        # The tracks whose patches read knob +name+ while building, playing
        # now (or queued to).
        def build_knob_tracks(name)
          list = @build_knob_lock.synchronize { @build_knobs[name]&.dup } || []
          list.select { |t| @tracks[t]&.patch? && @session.playing_after_queue?(t) }
        end

        # True if knob +name+ is a build knob of a track (see BuildKnobs).
        def build_knob?(name)
          @build_knob_lock.synchronize { @build_knobs.key?(name) }
        end

        # The build knobs track +track+'s patch read (names; the inspector
        # turns them a step a key: UI::Inspect).  Takes no render lock.
        def build_knobs_of(track)
          @build_knob_lock.synchronize { @build_knobs.select { |_, list| list.include?(track) }.keys }
        end

        # Turns build knob +k+ to +value+ and rebuilds +tracks+ at +point+
        # (a LaunchPoint; each track's quantization by default), in one
        # Session#command.  The knob lands with the rebuilt graphs.  Returns
        # the journal entries of the rebuilds.
        def turn_build_knob(k, value, tracks, point: LaunchPoint::NONE, fade: nil)
          turn_build_knobs({ k => value }, tracks, point: point, fade: fade)
        end

        # Turns several build knobs at once (+pairs+: { knob => value }) and
        # rebuilds +tracks+ once with all of them (hand-tune-2: a grouped
        # `turn :kick, clip: 0.3, drive: 2`; two rebuilds for one launch
        # point would keep only the first), in one Session#command.
        def turn_build_knobs(pairs, tracks, point: LaunchPoint::NONE, fade: nil)
          entries = []
          label = pairs.map { |k, v| "#{k.name.inspect} #{Param.literal(v) rescue v}" }.join(', ')
          @session.command("turn #{label} (rebuilds #{tracks.join(', ')})") {
            before = undo_state
            first = nil
            pairs.each { |k, v| k.build_value = v }
            begin
              tracks.each do |name|
                tr = @tracks[name] or next
                c = rebuild_track(tr, point, fade, carry: true)
                first ||= c&.time || resolve(tr.q || @quant, tr, point)
                entries << c
              end
            ensure
              pairs.each_key { |k| k.build_value = nil }
            end
            pairs.each { |k, v| @session.turn(k.name, v, start_time: first, build: true) }
            @session.note_undo_extra(self, before, undo_state)
          }
          entries.compact.map { |e| @session.journal[e.seq] }
        end
      end

      include BuildKnobs
    end
  end
end
