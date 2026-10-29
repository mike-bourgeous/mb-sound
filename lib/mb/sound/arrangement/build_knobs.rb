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

        # Turns build knob +k+ to +value+ and rebuilds +tracks+ at +point+
        # (a LaunchPoint; each track's quantization by default), in one
        # Session#command.  The knob lands with the rebuilt graphs.  Returns
        # the journal entries of the rebuilds.
        def turn_build_knob(k, value, tracks, point: LaunchPoint::NONE, fade: nil)
          entries = []
          @session.command("turn #{k.name.inspect} #{Param.literal(value) rescue value} (rebuilds #{tracks.join(', ')})") {
            before = undo_state
            first = nil
            k.build_value = value
            begin
              tracks.each do |name|
                tr = @tracks[name] or next
                time = resolve(tr.q || @quant, tr, point)
                first ||= time
                entries << start_track(tr, tr.clip, time, fade)
              end
            ensure
              k.build_value = nil
            end
            @session.turn(k.name, value, start_time: first, build: true)
            @session.note_undo_extra(self, before, undo_state)
          }
          entries.compact.map { |e| @session.journal[e.seq] }
        end
      end

      include BuildKnobs
    end
  end
end
