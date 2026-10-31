module MB
  module Sound
    class Arrangement
      # Tracks on the CUE route (see Session::Cue and design/notes/cue.md):
      # a track's patch built on a clip and played on CUE as :"track/cue",
      # and the launch that brings it to MAIN at the track's launch point,
      # the cued clip becoming the track's clip.
      module Cue
        # Plays track +name+'s patch on +clip+ (a Clip or Kit, a clip slot
        # index or name, or nil for the track's clip) on CUE, at the launch
        # point +at:+ (a LaunchPoint; else the usual `bg` default), fading
        # in over +fade:+ bars.  A track without a patch (one graph) or
        # already playing without a new clip is pre-listened instead (see
        # Session::Cue#pfl).  Returns the Change or name.
        def cue(name, clip = nil, at: nil, fade: nil)
          tr = tracks[name] or raise ArgumentError, "No track #{name.inspect}"
          clip = find_slot(name, clip) || (return nil) if clip.is_a?(Symbol) || clip.is_a?(Integer)
          if !tr.patch? || (clip.nil? && @session.playing_after_queue?(name))
            return @session.pfl(name, true, time: @session.send(:launch_time, at, [], default: nil))
          end

          clip ||= tr.clip
          raise ArgumentError, "Track #{name.inspect} has no clip yet; cue it with one (`cue #{name.inspect}, clip`)" if clip.nil?
          check_clip(tr, clip)
          graph = GraphNode::Mixer.with_ring(@session.ring || GraphNode::Mixer.ring_mode) { tr.build(clip) }
          @session.note_cue_clip(name, clip)
          @session.cue_player(name, graph, at: at, fade: fade, description: "#{name}: #{name_of(clip)}")
        end

        # Launches the cue of track +name+ to MAIN at the track's launch
        # point (its +q:+, else the set's #quant; +at:+ overrides it, as in
        # #play), crossfading over +fade:+ bars.  The cued clip becomes the
        # track's clip.  Returns the Change.
        def launch_cue(name, at: nil, fade: nil, q: nil)
          tr = tracks[name] or raise ArgumentError, "No track #{name.inspect}"
          time = resolve(tr.q || q || @quant, tr, at)
          clip = @session.cued_clip(name)
          result = @session.launch_cue(name, time: time, fade: fade)
          @mutex.synchronize { tr.clip = clip } if result && clip
          result
        end

        # Cues every track scene +name+ gives a clip or kit (tracks with a
        # patch whose clip would change; see #cue).  Returns the changes.
        def cue_scene(name, at: nil, fade: nil)
          sc = scenes[name] or raise ArgumentError, "No scene #{name.inspect}"
          list = scene_cues(sc).map { |tr, clip| cue(tr.name, clip, at: at, fade: fade) }.compact
          return MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect} changes no track's clip; nothing to cue")) if list.empty?
          list
        end

        # Launches scene +name+ with its cued tracks taking over (#launch_cue
        # at each one's launch point, the same graphs carrying on), then
        # #go for the rest (tracks already playing the scene's clip are left
        # alone by #go).  Returns the scene's journal entry.
        def launch_cued_scene(name, at: nil, fade: nil)
          sc = scenes[name] or raise ArgumentError, "No scene #{name.inspect}"
          scene_cues(sc).each do |tr, clip|
            next unless @session.cued?(tr.name) && @session.cued_clip(tr.name).equal?(clip)
            launch_cue(tr.name, at: at, fade: fade.nil? ? sc.fade : fade, q: sc.q)
          end
          entry = go(name, at: at, fade: fade)
          # (inside the caller's command, #go returns nil: find its change)
          entry || (c = last_change(name)) && @session.journal[c.seq]
        end

        private

        # [track, clip] pairs scene +sc+ would give new clips.
        def scene_cues(sc)
          sc.values.filter_map { |k, v|
            tr = tracks[k]
            next unless tr&.patch? && (v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit))
            next if v.equal?(tr.clip) && @session.playing_after_queue?(tr.name)
            [tr, v]
          }
        end
      end

      include Cue
    end
  end
end
