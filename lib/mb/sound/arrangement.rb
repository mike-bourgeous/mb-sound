module MB
  module Sound
    # The Set layer above a Session (see design/notes/arrangement.md):
    # +tracks+ are named players that remember their patch (a block that
    # builds a graph from a clip) or graph, the clip they play, and their
    # launch quantization; +scenes+ are full states of the tracks (which
    # clip each one plays, or off), launched with #go.  Launching a scene
    # changes only what differs, at each track's launch point, as changes
    # in the Session's change queue (so they are exact, journaled, and
    # undoable as one step).
    #
    # Tracks and (later) knobs share one namespace of names; a name used
    # for two kinds of things goes through MB::Sound.live_error.
    #
    # One Arrangement belongs to each Session (Session#arrangement).  The
    # console methods are in ArrangementMethods.
    #
    # Launch points (+q:+, +quant+, +at:+) are :now, :beat, :bar, :clip, a
    # number of bars (e.g. 4 for the next 4-bar line), or a Duration (e.g.
    # 2.beats).  Unlike #bg's +at:+, plain numbers are bars, like fades.
    class Arrangement
      # A track: a +patch+ (a block that builds a graph from a clip, or
      # nil), a +graph+ (for tracks without a patch), its launch
      # quantization +q+ (nil for the set's), a +fade+ in bars for its
      # starts and stops (nil for none, with a declick on stops), and the
      # +clip+ it plays (or will play once queued changes land).
      Track = Struct.new(:name, :patch, :graph, :q, :fade, :clip, keyword_init: true) do
        def patch?
          !patch.nil?
        end
      end

      # A scene: what each track plays (+values+: a Clip or Kit, :on, :off
      # or nil, or :keep), its launch quantization +q+, a +fade+ for the
      # tracks that change, whether tracks it doesn't name stop or keep
      # playing (+others+: :stop or :keep), and a +block+ run at launch.
      Scene = Struct.new(:name, :values, :q, :fade, :others, :block, keyword_init: true)

      # Values a scene can give a track besides clips.
      TRACK_STATES = [:on, :off, :keep, true, false, nil].freeze

      attr_reader :session

      # The set-wide launch quantization (bars or a launch point; 1 bar by
      # default).
      attr_reader :quant

      # The scene launched last (by #go or undo).
      attr_reader :current_scene

      def initialize(session)
        @session = session
        @tracks = {}
        @scenes = {}
        @quant = 1
        @current_scene = nil
        @labels = {}.compare_by_identity
        @mutex = Mutex.new
      end

      # Sets the set-wide launch quantization (see the class comment).
      def quant=(q)
        check_quant(q)
        @quant = q
      end

      # The tracks (a Hash from name to Track).
      def tracks
        @mutex.synchronize { @tracks.dup }
      end

      # The scenes (a Hash from name to Scene).
      def scenes
        @mutex.synchronize { @scenes.dup }
      end

      # Defines (or redefines) a track named +name+: with a block, a patch
      # that builds the track's graph from the clip it plays (so scenes and
      # `bg :name, clip` can give it clips); otherwise a +graph+ to play.
      # +q:+ is the track's launch quantization (the set's #quant if nil),
      # and +fade:+ a fade in bars for its starts and stops.  Returns the
      # name.
      #
      #     track(:bass, q: 1) { |c| c.tone.ramp.lp4(800) * c.amp_env }
      #     track :pad, pad_graph
      def track(name, graph = nil, q: nil, fade: nil, &patch)
        raise ArgumentError, "Track names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        raise ArgumentError, 'Give a track a patch block or a graph, not both' if graph && patch
        raise ArgumentError, "Give track #{name.inspect} a patch block or a graph" unless graph || patch
        check_quant(q) if q
        return nil unless @session.names.claim(name, :track)

        @mutex.synchronize {
          old = @tracks[name]
          @tracks[name] = Track.new(name: name, patch: patch, graph: graph, q: q, fade: fade, clip: old&.clip)
        }
        name
      end

      # Gives clips names for #scenes and #tracks listings (e.g.
      # `label verse_bass: bass_a`).  Returns the names.
      def label(**clips)
        @mutex.synchronize { clips.each { |n, c| @labels[c] = n } }
        clips.keys
      end

      # A short name for a clip or state, for listings.
      def label_of(value)
        return value.inspect if TRACK_STATES.include?(value)
        @mutex.synchronize { @labels[value] }&.to_s || value.class.name.split('::').last.downcase
      end

      # Defines (or redefines) a scene: the state of every track.  Each
      # keyword names a track and gives a Clip or Kit to play, :on to play
      # what it played last (or its graph), :off or nil to stop, or :keep.
      # Tracks not named stop (a scene is a full state), unless +others:
      # :keep+ (a partial scene, e.g. a fill).  +q:+ is the scene's launch
      # quantization (tracks' own +q:+ come first), and +fade:+ a fade in
      # bars for the tracks that start or stop.  A block runs at launch for
      # anything else (it gets the launch time, and #bg and the other
      # commands inside it land there, like in an #at_bar block).  Returns
      # the name.
      #
      #     scene :verse, pad: chords_a, bass: bass_a, drums: beat
      #     scene :fill, drums: roll, others: :keep
      def scene(name, q: nil, fade: nil, others: :stop, **values, &block)
        raise ArgumentError, "Scene names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        raise ArgumentError, "others: must be :stop or :keep (got #{others.inspect})" unless [:stop, :keep].include?(others)
        check_quant(q) if q

        values.each_key do |k|
          kind = @session.names.kind(k)
          next if kind.nil? || kind == :track
          MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect}: #{k.inspect} is a #{kind}, not a track")) or return nil
        end

        @mutex.synchronize {
          @scenes[name] = Scene.new(name: name, values: values.freeze, q: q, fade: fade, others: others, block: block)
        }
        name
      end

      # Launches the scene +name+: each track that should change does, at
      # its launch point (+at:+ for every track if given, else the track's
      # +q:+, the scene's, or the set's #quant).  Tracks already playing
      # what the scene says are left alone, so a scene can be launched
      # again freely.  +fade:+ overrides the scene's fade.  Returns the
      # journal entry for the scene launch (it lands at the scene's launch
      # point).
      def go(name, at: nil, fade: nil)
        sc = @mutex.synchronize { @scenes[name] }
        if sc.nil?
          known = scenes.keys
          return MB::Sound.live_error(ArgumentError.new("No scene #{name.inspect}#{known.empty? ? '' : " (scenes: #{known.map(&:inspect).join(', ')})"}"))
        end

        unknown = sc.values.keys - tracks.keys
        unless unknown.empty?
          return MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect} names #{unknown.map(&:inspect).join(', ')}, which #{unknown.length == 1 ? 'is not a track' : 'are not tracks'}"))
        end

        _, changes = @session.command("go #{name.inspect}") {
          before = undo_state
          time = resolve(at || sc.q || @quant)
          entry = @session.change(:scene, name, time, data: { scene: name }) { |_t| }

          tracks.each_value do |tr|
            value = sc.values.key?(tr.name) ? sc.values[tr.name] : (sc.others == :keep ? :keep : :off)
            next if value == :keep
            set_track(tr, value, resolve(at || tr.q || sc.q || @quant, tr), fade: fade.nil? ? sc.fade : fade)
          end

          if sc.block
            Session.with_context(session: @session, time: time, source: :set) { sc.block.call(time) }
          end

          @mutex.synchronize { @current_scene = name }
          @session.note_undo_extra(self, before, undo_state)
          entry
        }

        scene_change = changes&.find { |c| c.kind == :scene }
        scene_change && @session.journal[scene_change.seq]
      end

      # Plays +value+ (a Clip or Kit for a track with a patch, :on, or
      # :off) on track +name+ at +at:+ or +start_time:+ (else the track's
      # launch point).  Used by `bg :name, clip` on tracks.  Returns the
      # journal entry of the track's change.
      def play(name, value, at: nil, start_time: nil, fade: nil)
        tr = tracks[name] or raise ArgumentError, "No track #{name.inspect}"
        result = nil
        @session.command("bg #{name.inspect}") {
          before = undo_state
          time = start_time ? start_time.to_r : resolve(at || tr.q || @quant, tr)
          result = set_track(tr, value, time, fade: fade)
          @session.note_undo_extra(self, before, undo_state)
        }
        result && @session.journal[result.seq]
      end

      # A listing of the tracks: name => "q:1 bass_a (playing)".
      def track_info
        tracks.transform_values { |tr|
          state = @session.playing_after_queue?(tr.name) ? 'playing' : 'stopped'
          state += ', muted' if @session.muted?(tr.name)
          state += ', soloed' if @session.soloed?(tr.name)
          what = tr.patch? ? (tr.clip ? label_of(tr.clip) : 'no clip') : 'graph'
          "q:#{(tr.q || @quant).inspect} #{what} (#{state})"
        }
      end

      # A listing of the scenes: name => "pad:chords_a bass:bass_a", with
      # the current scene marked.
      def scene_info
        scenes.transform_values { |sc|
          parts = sc.values.map { |k, v| "#{k}:#{label_of(v)}" }
          parts << 'others:keep' if sc.others == :keep
          parts << "q:#{sc.q.inspect}" if sc.q
          parts << '(block)' if sc.block
          "#{sc.name == @current_scene ? '▶ ' : ''}#{parts.join(' ')}"
        }
      end

      # The Set state for undo (see Session#note_undo_extra).
      def undo_state
        @mutex.synchronize { { clips: @tracks.transform_values(&:clip), scene: @current_scene } }
      end

      # Puts the Set state back (called by Session undo and redo).
      def restore_undo_state(state)
        @mutex.synchronize {
          state[:clips].each { |n, c| @tracks[n].clip = c if @tracks[n] }
          @current_scene = state[:scene]
        }
      end

      # Resolves a launch point (see the class comment) to an exact
      # timeline position, counting from Session#now.  +track+ gives :clip
      # the track's clips.
      def resolve(q, track = nil)
        q = :now if q == 0
        at = case q
             when Symbol then q
             when Sequence::Duration then q.whole_notes
             when Numeric then Sequence::Duration.rational(q) * @session.transport.bar_length
             else raise ArgumentError, "Unknown launch point #{q.inspect}"
             end
        nodes = q == :clip && track ? @session.timeline_nodes_of(track.name) : []
        @session.send(:launch_time, at, nodes)
      end

      private

      def check_quant(q)
        ok = q.is_a?(Sequence::Duration) || Session::LAUNCH_POINTS.include?(q) || (q.is_a?(Numeric) && q >= 0)
        raise ArgumentError, "Launch quantization must be #{Session::LAUNCH_POINTS.map(&:inspect).join(', ')}, a number of bars, or a Duration (got #{q.inspect})" unless ok
      end

      # Changes track +tr+ to +value+ at +time+.  Returns the last change
      # made (or nil).
      def set_track(tr, value, time, fade:)
        fade = tr.fade if fade.nil?
        playing = @session.playing_after_queue?(tr.name)

        case value
        when :off, false, nil
          return nil unless playing
          @session.remove(tr.name, fade: fade || @session.declick_bars, time: time)
          last_change(tr.name)

        when :on, true
          return nil if playing
          start_track(tr, tr.clip, time, fade)

        else
          check_clip(tr, value)
          if playing && tr.clip.equal?(value)
            nil
          elsif playing && tr.patch? && tr.clip
            begin
              @session.swap(tr.name, { tr.clip => value }, start_time: time)
              @mutex.synchronize { tr.clip = value }
              last_change(tr.name)
            rescue ArgumentError
              # The patch doesn't play the clip in a way swap can find;
              # build it again with the new clip
              start_track(tr, value, time, fade)
            end
          elsif playing
            @session.swap(tr.name, value, start_time: time)
            @mutex.synchronize { tr.clip = value }
            last_change(tr.name)
          else
            start_track(tr, value, time, fade)
          end
        end
      end

      # Starts track +tr+ with +clip+ at +time+: builds its patch, or plays
      # its graph (resuming it if it was stopped).
      def start_track(tr, clip, time, fade)
        if tr.patch?
          raise ArgumentError, "Track #{tr.name.inspect} has a patch; give it a clip to play" if clip.nil?
          graph = tr.patch.call(clip)
          @session.add(graph, name: tr.name, start_time: time, fade: fade || 0, description: "#{tr.name}: #{label_of(clip)}")
          @mutex.synchronize { tr.clip = clip }
        elsif @session.stopped.key?(tr.name)
          @session.resume(tr.name, start_time: time, fade: fade || 0)
          @session.swap(tr.name, clip, start_time: time) if clip && !clip.equal?(tr.clip)
        else
          @session.add(tr.graph, name: tr.name, start_time: time, fade: fade || 0)
          @session.swap(tr.name, clip, start_time: time) if clip
        end
        @mutex.synchronize { tr.clip = clip } if clip
        last_change(tr.name)
      end

      # The last change made for +name+ by the command running now.
      def last_change(name)
        group = Thread.current[:mb_sound_command]
        group && group[:changes].reverse.find { |c| c.subject == name }
      end

      def check_clip(tr, value)
        ok = value.is_a?(Sequence::Clip) || value.is_a?(Sequence::Kit) || value.is_a?(Hash)
        raise ArgumentError, "Track #{tr.name.inspect}: give a Clip, a Kit, :on, :off, or :keep (got #{value.class})" unless ok
      end
    end
  end
end
