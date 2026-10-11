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
    # Launch quantizations (+q:+, +quant+) are alignments like +on:+ (see
    # LaunchPoint): :now, :beat, :bar, :clip, a number of bars (e.g. 4 for
    # the next 4-bar line), or a Duration (e.g. 2.beats).  #go and #play
    # also take +on:+ (which overrides them), and +in:+ and +at:+ (after
    # which tracks still align to their quantization).
    class Arrangement
      include Recording

      # A track: a +patch+ (a block that builds a graph from a clip, or
      # nil), a +graph+ (for tracks without a patch), its launch
      # quantization +q+ (nil for the set's), a +fade+ in bars for its
      # starts and stops (nil for none, with a declick on stops), the
      # +clip+ it plays (or will play once queued changes land), its +lead+
      # (how early it plays: bars, a Duration, a Length, or :attack) and
      # +nudge+ (a timing offset, negative for early: a Length or
      # Duration), and +ahead+, the two combined in whole notes (see
      # #track).
      Track = Struct.new(:name, :patch, :graph, :q, :fade, :clip, :lead, :nudge, :ahead, keyword_init: true) do
        def patch?
          !patch.nil?
        end
      end

      # A scene: what each track plays (+values+: a Clip or Kit, :on, :off
      # or nil, :cut, or :keep), its launch quantization +q+, a +fade+ for
      # the tracks that change, what happens to tracks it doesn't name
      # (+others+: :stop (or :ring) rings them out, :cut cuts them, :keep
      # keeps them playing), and a +block+ run at launch.  Tracks a scene
      # stops ring out unless +others+ is :cut (tracks given :cut always
      # cut).
      Scene = Struct.new(:name, :values, :q, :fade, :others, :block, keyword_init: true)

      # Values a scene can give a track besides clips.
      TRACK_STATES = [:on, :off, :cut, :keep, true, false, nil].freeze

      # How a scene stops tracks: :stop (or :ring) rings them out, :cut
      # stops them with a 5 ms declick (see Scene's +others+).
      STOP_MODES = [:stop, :ring, :cut].freeze

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
        @mutex = Mutex.new
        @sections = {}
        @playback = nil
      end

      # Sections declared outside a form with #section (a Hash from name to
      # Form::Section), which bare calls in a `flow` block can play.
      def sections
        @mutex.synchronize { @sections.dup }
      end

      # Declares a section outside a form (see Form::Builder for the
      # options): `section :verse, 8.bars, fill: :roll`.  Returns the
      # Form::Section.
      def section(name, length, times: 1, fill: nil, scene: nil, fade: nil, **others)
        raise ArgumentError, "#{name}: sections no longer take next: (what follows belongs to the flow: goto and pick)" if others.key?(:next)
        knobs = Session.with_context(session: @session) { Form.section_options(name, others)[1] }
        knobs.each { |k, v| check_knob_value(name, k, v) or return nil }
        sec = Form::Section.new(name: name, length: length, times: times, fill: Form::Fill.from(fill, section: name), scene: scene, fade: fade, knobs: knobs)
        @mutex.synchronize { @sections[name] = sec }
      end

      # Builds a Form from a block (see Form::Builder), with the sections
      # declared by #section available to bare calls.
      def build_form(&block)
        Form.build(sections: sections, &block)
      end

      # The form playing (or played last), a Form::Playback, or nil.
      attr_reader :playback

      # Plays +form+ (a Form) from its launch point (+on:+, +in:+, +at:+;
      # the next bar by default, or now if nothing plays), replacing any
      # form already playing (which stops launching sections).  +seed+ seeds
      # its chance (weighted gotos and picks; MB::Sound.next_seed by default, so takes
      # replay the same choices).  Returns the Form::Playback.
      def play_form(form, at: nil, on: nil, in: nil, seed: nil)
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, "Expected a Form (got #{form.class})" unless form.is_a?(Form)

        seed ||= MB::Sound.next_seed
        pb = Form::Playback.new(self, form, seed: seed)
        time = @session.send(:launch_time, point, [])
        old = @mutex.synchronize { prev = @playback; @playback = pb; prev }
        old&.stop
        pb.start(time)
        @session.ensure_running
        pb
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
      # +lead:+ plays the track early (maintainer, 2026-10-11: "Slow pads
      # sometimes need to lead the beat because of their slow attack"):
      # its clips' notes sound that much before the timeline, and its
      # launches, swaps, and stops land that much early, so a slow attack
      # peaks on the downbeat.  Bars (plain numbers), a Duration, a Length,
      # or :attack (the attack time of the patch's amplitude envelope, the
      # longest `amp_env` attack in its graph, else the longest envelope
      # attack; measured each time the patch is built).  +nudge:+ moves its
      # notes by a fixed time (a Length or Duration; negative pushes them
      # early for urgency, positive pulls them late to relax, like a
      # drummer's backbeat: `nudge: 6.ms`).  Both apply to clip-driven
      # graphs (MIDI::ClipSource#ahead).
      #
      #     track(:bass, q: 1) { |c| c.tone.ramp.lp4(800) * c.amp_env }
      #     track :pad, pad_graph
      #     track(:pad, lead: :attack) { |c| c.synth { |v| v.hz.saw * v.amp_env(1.5, 1, 0.8, 2) } }
      #     track(:drums, nudge: 5.ms) { |k| tr808(k) }
      def track(name, graph = nil, q: nil, fade: nil, lead: nil, nudge: nil, &patch)
        raise ArgumentError, "Track names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        raise ArgumentError, 'Give a track a patch block or a graph, not both' if graph && patch
        raise ArgumentError, "Give track #{name.inspect} a patch block or a graph" unless graph || patch
        check_quant(q) if q
        check_offset(:lead, lead) unless lead == :attack
        check_offset(:nudge, nudge)
        raise ArgumentError, "nudge: takes a Length or Duration (e.g. 5.ms; got #{nudge.inspect})" if nudge.is_a?(Numeric)
        return nil unless @session.names.claim(name, :track)

        tr = nil
        @mutex.synchronize {
          old = @tracks[name]
          tr = @tracks[name] = Track.new(name: name, patch: patch, graph: graph, q: q, fade: fade, clip: old&.clip, lead: lead, nudge: nudge, ahead: 0r)
        }
        set_ahead(tr, graph) if graph || lead != :attack
        name
      end

      # How far ahead of the timeline track +name+ plays, in whole notes
      # (see #track's +lead:+ and +nudge:+).
      def ahead(name)
        tracks[name]&.ahead || 0r
      end

      # A short name for a clip, kit, or state, for listings: the name
      # given with Sequence::Named#named (`bass_a.named(:bass_a)`), else
      # the kind of value (seq, clip, kit).
      def name_of(value)
        return value.inspect if TRACK_STATES.include?(value)
        return MB::M.sigfigs(value, 4).to_s if value.is_a?(Numeric)
        return value.inspect if value.is_a?(Symbol)
        return "#{name_of(value[0])}~" if value.is_a?(Array)
        return value.name.to_s if value.respond_to?(:named?) && value.named?
        value.class.name.split('::').last.downcase
      end

      # Defines (or redefines) a scene: the state of every track.  Each
      # keyword names a track and gives a Clip or Kit to play, :on to play
      # what it played last (or its graph), :off or nil to stop, or :keep.
      # Tracks not named stop (a scene is a full state), unless +others:
      # :keep+ (a partial scene, e.g. a fill).  Stopping tracks ring out:
      # their clips stop sending notes at the launch point and the track
      # plays on until it is silent (see Session::Tails), so releases,
      # delays, and reverbs inside it finish.  +others: :cut+ (or a track's
      # value :cut) stops with a 5 ms declick instead, and +fade:+ fades.  +q:+ is the scene's launch
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
        raise ArgumentError, "others: must be :stop (or :ring), :cut, or :keep (got #{others.inspect})" unless [*STOP_MODES, :keep].include?(others)
        check_quant(q) if q

        values.each do |k, v|
          kind = @session.names.kind(k)
          if kind == :knob
            check_knob_value(name, k, v) or return nil
            next
          end
          next if kind.nil? || kind == :track
          MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect}: #{k.inspect} is a #{kind}, not a track or knob")) or return nil
        end

        @mutex.synchronize {
          @scenes[name] = Scene.new(name: name, values: values.freeze, q: q, fade: fade, others: others, block: block)
        }
        name
      end

      # Launches the scene +name+: each track that should change does, at
      # its launch point (+on:+, +in:+, +at:+ for every track if given (see
      # LaunchPoint), else the track's +q:+, the scene's, or the set's
      # #quant).  Tracks already playing
      # what the scene says are left alone, so a scene can be launched
      # again freely.  +fade:+ overrides the scene's fade.  Returns the
      # journal entry for the scene launch (it lands at the scene's launch
      # point).
      def go(name, at: nil, on: nil, in: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        sc = @mutex.synchronize { @scenes[name] }
        if sc.nil?
          known = scenes.keys
          return MB::Sound.live_error(ArgumentError.new("No scene #{name.inspect}#{known.empty? ? '' : " (scenes: #{known.map(&:inspect).join(', ')})"}"))
        end

        knob_values = sc.values.select { |k, _| @session.names.kind(k) == :knob }
        unknown = sc.values.keys - tracks.keys - knob_values.keys
        unless unknown.empty?
          return MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect} names #{unknown.map(&:inspect).join(', ')}, which #{unknown.length == 1 ? 'is not a track or knob' : 'are not tracks or knobs'}"))
        end

        _, changes = @session.command("go #{name.inspect}") {
          before = undo_state
          time = resolve(sc.q || @quant, nil, point)
          entry = @session.change(:scene, name, time, data: { scene: name }) { |_t| }

          # Knobs turn at the scene's launch point (a number, a node or
          # knob name to follow, or [value, over: ..., curve: ...])
          knob_values.each do |k, v|
            turn_knob(k, v, time)
          end

          tracks.each_value do |tr|
            value = sc.values.key?(tr.name) ? sc.values[tr.name] : (sc.others == :keep ? :keep : :off)
            next if value == :keep
            stop = sc.others == :cut ? :cut : :ring
            set_track(tr, value, resolve(tr.q || sc.q || @quant, tr, point), fade: fade.nil? ? sc.fade : fade, stop: stop)
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
      # :off) on track +name+ at the launch point (+on:+, +in:+, +at:+; see
      # LaunchPoint) or +start_time:+ (else the track's +q:+ or the set's
      # #quant).  Used by `bg :name, clip` on tracks.  Returns the
      # journal entry of the track's change.
      def play(name, value, at: nil, on: nil, in: nil, start_time: nil, fade: nil)
        point = LaunchPoint.of(binding) or return nil
        tr = tracks[name] or raise ArgumentError, "No track #{name.inspect}"
        result = nil
        @session.command("bg #{name.inspect}") {
          before = undo_state
          time = start_time ? start_time.to_r : resolve(tr.q || @quant, tr, point)
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
          state += ', armed' if armed?(tr.name)
          what = tr.patch? ? (tr.clip ? name_of(tr.clip) : 'no clip') : 'graph'
          lead = tr.ahead && !tr.ahead.zero? ? " #{tr.ahead > 0 ? 'ahead' : 'behind'} #{MB::M.sigfigs((tr.ahead.abs / @session.transport.whole_notes_per_second * 1000).to_f, 3)} ms" : ''
          "q:#{(tr.q || @quant).inspect} #{what}#{lead} (#{state})"
        }
      end

      # A listing of the scenes: name => "pad:chords_a bass:bass_a", with
      # the current scene marked.
      def scene_info
        scenes.transform_values { |sc|
          parts = sc.values.map { |k, v| "#{k}:#{name_of(v)}" }
          parts << 'others:keep' if sc.others == :keep
          parts << "q:#{sc.q.inspect}" if sc.q
          parts << '(block)' if sc.block
          "#{sc.name == @current_scene ? '▶ ' : ''}#{parts.join(' ')}"
        }
      end

      # The Set state for undo (see Session#note_undo_extra).
      def undo_state
        @mutex.synchronize { { clips: @tracks.transform_values(&:clip), scene: @current_scene, armed: (@armed || {}).dup } }
      end

      # Puts the Set state back (called by Session undo and redo).
      def restore_undo_state(state)
        @mutex.synchronize {
          state[:clips].each { |n, c| @tracks[n].clip = c if @tracks[n] }
          @current_scene = state[:scene]
          @armed = state[:armed].dup if state[:armed]
        }
      end

      # Resolves launch quantization +q+ (see the class comment), after
      # +point+'s +in:+ or +at:+ if given (a LaunchPoint; its +on:+
      # replaces +q+), to an exact timeline position, counting from
      # Session#now.  +track+ gives :clip the track's clips.
      def resolve(q, track = nil, point = nil)
        point ||= LaunchPoint::NONE
        nodes = (point.on || q) == :clip && track ? @session.timeline_nodes_of(track.name) : []
        @session.send(:launch_time, point, nodes, default: q)
      end

      private

      # Turns knob +name+ to a scene's or section's +value+ at +time+: a
      # number, a node or knob name to follow, or an Array of a value and
      # turn options (`[8000, over: 2.bars, curve: :smooth]`).
      def turn_knob(name, value, time)
        v, options = knob_value(value)
        @session.turn(name, v, start_time: time, **options)
      end

      # Splits a scene's knob value into the value and turn options.
      def knob_value(value)
        return [value, {}] unless value.is_a?(Array)
        v, options = value
        [v, (options || {}).slice(:over, :curve, :smooth, :from)]
      end

      # Checks a scene's (or section's) knob value; false (after
      # live_error) if it can't be used.
      def check_knob_value(owner, name, value)
        v, options = knob_value(value)
        ok = v.is_a?(Numeric) || v.is_a?(Symbol) || v.respond_to?(:sample)
        extra = value.is_a?(Array) ? ((value[1] || {}).keys - [:over, :curve, :smooth, :from]) : []
        ok &&= extra.empty? && (!value.is_a?(Array) || value.length <= 2) && options.is_a?(Hash)
        return true if ok
        !!MB::Sound.live_error(ArgumentError.new("#{owner.inspect}: knob #{name.inspect} takes a number, a node, a knob name, or [value, over:, curve:, from:] (got #{value.inspect})"))
      end

      def check_quant(q)
        ok = q.is_a?(Length) || Session::LAUNCH_POINTS.include?(q) || (q.is_a?(Numeric) && q >= 0)
        raise ArgumentError, "Launch quantization must be #{Session::LAUNCH_POINTS.map(&:inspect).join(', ')}, a number of bars, or a Duration (got #{q.inspect})" unless ok
      end

      # Changes track +tr+ to +value+ at +time+.  Returns the last change
      # made (or nil).
      #
      # Stopping tracks ring out (+stop: :ring+; see Session::Tails) unless
      # given a fade, +stop: :cut+, or the value :cut (a 5 ms declick).
      def set_track(tr, value, time, fade:, stop: :ring)
        fade = tr.fade if fade.nil?
        playing = @session.playing_after_queue?(tr.name)
        musical = time
        time = early(tr, time)

        case value
        when :off, :cut, false, nil
          return nil unless playing
          if fade || value == :cut || stop == :cut
            @session.remove(tr.name, fade: fade || @session.declick_bars, time: time)
          else
            @session.remove(tr.name, ring: true, time: time)
          end
          last_change(tr.name)

        when :on, true
          return nil if playing
          start_track(tr, tr.clip, musical, fade)

        else
          check_clip(tr, value)
          if playing && tr.clip.equal?(value)
            nil
          elsif playing && tr.patch? && (tr.clip.nil? || new_rows?(tr.clip, value))
            start_track(tr, value, musical, fade)
          elsif playing && tr.patch?
            begin
              @session.swap(tr.name, { tr.clip => value }, start_time: time)
              @mutex.synchronize { tr.clip = value }
              last_change(tr.name)
            rescue ArgumentError
              # The patch doesn't play the clip in a way swap can find;
              # build it again with the new clip
              start_track(tr, value, musical, fade)
            end
          elsif playing
            @session.swap(tr.name, tr.clip && !value.is_a?(Sequence::Clip) ? { tr.clip => value } : value, start_time: time)
            @mutex.synchronize { tr.clip = value }
            last_change(tr.name)
          else
            start_track(tr, value, musical, fade)
          end
        end
      end

      # +time+ for a change to track +tr+: #ahead earlier (see #track).
      def early(tr, time)
        tr.ahead.nil? || tr.ahead.zero? ? time : time - tr.ahead
      end

      # Computes track +tr+'s #ahead (for :attack, from +graph+'s
      # envelopes) and gives it to +graph+'s clip sources.
      def set_ahead(tr, graph)
        lead = tr.lead == :attack ? attack_lead(graph) : tr.lead
        ahead = whole_notes(lead) - whole_notes(tr.nudge)
        @mutex.synchronize { tr.ahead = ahead }
        @session.timeline_nodes_in(graph).grep(MIDI::ClipSource).each { |s| s.ahead = ahead } if graph
        ahead
      end

      # The attack time (a Length) of +graph+'s amplitude envelope: the
      # longest attack of envelopes made by amp_env, else of any envelope
      # (0 without envelopes).
      def attack_lead(graph)
        envs = @session.send(:to_nodes, graph).flat_map { |n| [n, *n.graph] }.grep(MB::Sound::Envelope).uniq
        amp = envs.select { |e| e.preset_name == :amp_env }
        times = (amp.empty? ? envs : amp).filter_map { |e| e.attack_time rescue nil }
        (times.max || 0).to_f.seconds
      end

      # A lead or nudge in whole notes at the current tempo.
      def whole_notes(v)
        t = @session.transport
        case v
        when nil then 0r
        when Sequence::Duration then v.to_r
        when Length then Sequence::Duration.rational(Length.seconds(v, transport: t) * t.whole_notes_per_second)
        else Sequence::Duration.rational(v) * t.bar_length
        end
      end

      def check_offset(name, v)
        ok = v.nil? || v.is_a?(Length) || (v.is_a?(Numeric) && v.real? && v.finite?)
        raise ArgumentError, "#{name}: takes bars, a Duration, or a Length#{name == :lead ? ', or :attack' : ''} (got #{v.inspect})" unless ok
      end

      # Starts track +tr+ with +clip+ at +time+: builds its patch, or plays
      # its graph (resuming it if it was stopped).
      def start_track(tr, clip, time, fade)
        musical = time
        time = early(tr, time)
        if tr.patch? && clip && clip.equal?(tr.clip) && @session.ringing?(tr.name)
          # Still ringing out with this clip: bring the same graph back
          @session.resume(tr.name, start_time: time, fade: 0)
        elsif tr.patch?
          raise ArgumentError, "Track #{tr.name.inspect} has a patch; give it a clip to play" if clip.nil?
          graph = tr.patch.call(clip)
          set_ahead(tr, graph)
          time = early(tr, musical) # (an attack lead is measured on the new graph)
          @session.add(graph, name: tr.name, start_time: time, fade: fade || 0, description: "#{tr.name}: #{name_of(clip)}")
          @mutex.synchronize { tr.clip = clip }
        elsif @session.resumable?(tr.name)
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

      # True if +value+ is a Kit with rows +old+ doesn't have (a patch built
      # from +old+ has no voices for them, so it is built again instead of
      # swapped).
      def new_rows?(old, value)
        return false unless value.is_a?(Sequence::Kit)
        return true unless old.is_a?(Sequence::Kit)
        !(value.rows.keys - old.rows.keys).empty?
      end

      def check_clip(tr, value)
        ok = value.is_a?(Sequence::Clip) || value.is_a?(Sequence::Kit) || value.is_a?(Hash)
        raise ArgumentError, "Track #{tr.name.inspect}: give a Clip, a Kit, :on, :off, or :keep (got #{value.class})" unless ok
      end
    end
  end
end
