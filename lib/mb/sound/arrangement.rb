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
      include PatchCheck
      include ClipMatrix

      # A track: a +patch+ (a block that builds a graph from a clip, or
      # nil), a +graph+ (for tracks without a patch), its launch
      # quantization +q+ (nil for the set's), a +fade+ in bars for its
      # starts and stops (nil for none, with a declick on stops), the
      # +clip+ it plays (or will play once queued changes land), its +lead+
      # (how early it plays: bars, a Duration, a Length, or a
      # Length::Attack such as `0.5.attack`; `lead: :attack` is stored as
      # `1.attack`) and
      # +nudge+ (a timing offset, negative for early: a Length or
      # Duration), +lead_max+ (the cap of an attack lead), and +ahead+,
      # the lead and nudge combined in whole notes, and +capped+ (true if
      # an attack lead hit its cap) (see #track).
      # The longest lead a `lead: :attack` track takes by default (bars;
      # see #track's +lead_max:+).  Maintainer-approved 2026-10-11.
      ATTACK_LEAD_MAX = 1

      Track = Struct.new(:name, :patch, :graph, :q, :fade, :clip, :lead, :nudge, :ahead, :lead_max, :capped, :clock, :clocked, :trigger, keyword_init: true) do
        def patch?
          !patch.nil?
        end

        # +clip+ on the track's clock (the same clocked copy each time, so
        # a scene giving the clip again finds it playing), or +clip+.
        def clocked_clip(clip)
          return clip unless clock && clip.is_a?(Sequence::Clip) && clip.clocking.nil?
          (self.clocked ||= {}.compare_by_identity)[clip] ||= clip.clocked(clock)
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
        @arms = {} # (Recording: name => Arm)
        @patch_checked = nil # (PatchCheck: patch => clips checked)
        @failed_tracks = {} # track name => why its last definition failed (see #track, #scene)
        @last_patch_error = nil # (PatchCheck#report_patch_error)
        @demo_document = nil
        @slots = {} # (ClipMatrix: name => clips)
        @launch_clips = {} # (ClipMatrix: journal seq => clip)
        @tweaks = {}.compare_by_identity # (ClipMatrix: tweak version => its root, mark, transforms)
        @versions = {} # (ClipMatrix: version root => last version made)
        @form_checks = [] # (#before_form: Procs called with each Form #play_form starts)
        @warmed = nil # (#warm_up: track name => clips warmed => patch)
        @rehearsable = {} # (#warm_up: track name => its patch if every build played, else false)
        @rehearsal = nil # (#warm_up: sections rehearsed)
        @exercise_skipped = [] # (#warm_up: tracks whose exercise raised)
      end

      # Calls +block+ with each Form #play_form is about to start, before
      # its warm-up and before anything changes; an exception from the block
      # stops it there.  ScriptRunner checks --from/--to this way, so a
      # misspelled section is one line before a 2 s warm-up (ux-fix-2).
      # Returns +block+ (for #remove_before_form).
      def before_form(&block)
        raise ArgumentError, 'Pass a block that checks the form' unless block
        @mutex.synchronize { @form_checks << block }
        block
      end

      # Removes a block added with #before_form.
      def remove_before_form(block)
        @mutex.synchronize { @form_checks.delete(block) }
        nil
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
      # declared by #section available to bare calls.  The form is kept as
      # #last_form (whether or not it plays).
      def build_form(&block)
        Form.build(sections: sections, &block).tap { |f| @mutex.synchronize { @last_form = f } }
      end

      # The form built last (by `flow`, played or not), or nil.  Set
      # documents save the playing form, else this one.
      def last_form
        @mutex.synchronize { @last_form }
      end

      # The form playing (or played last), a Form::Playback, or nil.
      attr_reader :playback

      # Plays +form+ (a Form) from its launch point (+on:+, +in:+, +at:+;
      # the next bar by default, or now if nothing plays), replacing any
      # form already playing (which stops launching sections).  +seed+ seeds
      # its chance (weighted gotos and picks; MB::Sound.next_seed by default, so takes
      # replay the same choices).  +warm_up+ builds every track's patch once
      # first (see #warm_up): :auto (the default) for a realtime session
      # with YJIT that isn't playing yet, true, or false (`flow(warm_up:
      # false) { }` in the console); when it runs it prints one line
      # ("Warmed up 12 tracks in 2.0 s").  Returns the Form::Playback.
      def play_form(form, at: nil, on: nil, in: nil, seed: nil, warm_up: :auto)
        point = LaunchPoint.of(binding) or return nil
        raise ArgumentError, "Expected a Form (got #{form.class})" unless form.is_a?(Form)
        @mutex.synchronize { @form_checks.dup }.each { |check| check.call(form) }

        # Compile the tracks' builds before the first scene change needs them
        raise ArgumentError, "warm_up: must be :auto, true, or false (got #{warm_up.inspect})" unless [:auto, true, false].include?(warm_up)
        if warm_up == true || (warm_up == :auto && @session.realtime? && @session.idle? && defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)
          t0 = MB::U.clock_now
          result = self.warm_up(form: form)
          sections = @rehearsal if result
          if result && (!result.empty? || sections)
            built = result.count { |_, (_, how)| how == :built }
            skipped = @exercise_skipped.empty? ? '' : "skipped #{@exercise_skipped.join(', ')}; "
            puts format("\e[2mWarmed up %d track%s%s in %.1f s (%s%sskip with warm_up: false)\e[0m",
              result.length, result.length == 1 ? '' : 's', sections ? " and #{sections} section#{sections == 1 ? '' : 's'}" : '',
              MB::U.clock_now - t0, built > 0 ? "#{built} only built, reaching nodes made outside their patch; " : '', skipped)
          end
        end

        launch_form(form, point, seed || MB::Sound.next_seed)
      end

      # Sets the set-wide launch quantization (see the class comment).
      def quant=(q)
        check_quant(q)
        @quant = q
      end

      # The set document `demo` loaded into this Session (see
      # DemoMethods), or nil.
      attr_accessor :demo_document

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
      # attack; measured each time the patch is built), or attack times
      # like any other unit: `1.attack` is :attack, `0.5.attack` half of it
      # (Numeric#attack, Length::Attack; maintainer, 2026-10-11: "Might be
      # good to have a fractional lead amount on the attack as well" and
      # "What about lead: 0.5.attack so attack is like any other time
      # unit?": half a slow swell before the beat, half after), capped at
      # +lead_max:+ (default ATTACK_LEAD_MAX, 1 bar: a 4 s pad attack
      # would lead by 2 bars at 120 BPM, starting before the previous
      # section's last bar; bars, a Duration, or a Length; `tracks` says
      # "capped").  +nudge:+ moves its
      # notes by a fixed time (a Length or Duration; negative pushes them
      # early for urgency, positive pulls them late to relax, like a
      # drummer's backbeat: `nudge: 6.ms`).  Both apply to clip-driven
      # graphs (MIDI::ClipSource#ahead).
      #
      #     track(:bass, q: 1) { |c| c.tone.saw.lp4(800) * c.amp_env }
      #     track :pad, pad_graph
      #     track(:pad, lead: :attack) { |c| c.synth { |v| v.hz.saw * v.amp_env(1.5, 1, 0.8, 2) } }
      #     track(:swell, lead: :attack, lead_max: 2) { |c| c.synth { |v| v.hz.saw * v.amp_env(4, 1, 0.8, 2) } }
      #     track(:pad, lead: 0.5.attack) { |c| ... }   # half the attack before the beat
      #     track(:drums, nudge: 5.ms) { |k| tr808(k) }
      #
      # +send:+ (bus name => level) and +to:+ (a bus for the track's main
      # out, or :master) set the track's routing (see Session::Buses#route;
      # left as they are when not given):
      #
      #     track(:keys, send: { verb: -12.db }) { |c| c.synth { |v| v.hz.triangle * v.amp_env } }
      #     track(:kick, to: :drums) { |k| tr808(k) }
      #
      # +clock:+ plays the track's clips on a clock (a clock's name, a
      # Tempo, a Rational ratio, or a loop period; see MB::Sound::Clock):
      # every clip a scene, `bg`, or `launch` gives it (clips with a clock
      # of their own keep theirs).  A graph track's clips and loops are
      # clocked once.
      #
      #     track(:bowl, clock: :tide) { |c| c.trigger.resonate(:bowl) }
      #
      # +trigger: true+ makes it a trigger track (SidechainMethods#sidechain): heard
      # only by readers such as `duck(:name)`, never mixed (see
      # Session::Buses#route); +to:+ and +send:+ don't apply.
      def track(name, graph = nil, q: nil, fade: nil, lead: nil, nudge: nil, lead_max: nil, to: nil, send: nil, clock: nil, trigger: false, &patch)
        raise ArgumentError, "Track names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
        raise ArgumentError, 'Give a track a patch block or a graph, not both' if graph && patch
        raise ArgumentError, "Give track #{name.inspect} a patch block or a graph" unless graph || patch
        check_quant(q) if q
        lead = 1.attack if lead == :attack
        check_offset(:lead, lead) unless lead.is_a?(Length::Attack)
        check_offset(:nudge, nudge)
        check_offset(:lead_max, lead_max)
        raise ArgumentError, "lead_max: caps an attack lead (lead: :attack or 0.5.attack; got lead: #{lead.inspect})" if lead_max && !lead.is_a?(Length::Attack)
        raise ArgumentError, "nudge: takes a Length or Duration (e.g. 5.ms; got #{nudge.inspect})" if nudge.is_a?(Numeric)
        clock = Sequence::Clocked.check_name(clock) if clock.is_a?(Symbol)
        clock = MB::Sound::Clock.coerce(clock) unless clock.nil? || clock.is_a?(Symbol)
        graph = Sequence::Clocked.apply(graph, clock) if graph && clock
        # Built once now, so a broken patch fails here (see PatchCheck)
        begin
          ok = check_patch(name, patch, @mutex.synchronize { @tracks[name]&.clip })
        rescue PatchCheck::PatchError => e
          note_failed_track(name, e)
          raise
        end
        return note_failed_track(name, @last_patch_error) unless ok
        @mutex.synchronize { @failed_tracks.delete(name) }
        raise ArgumentError, "A trigger track's sound goes only to its readers (duck(#{name.inspect})); it takes no to: or send:" if trigger && (to || send)
        return nil unless @session.names.claim(name, :track)
        if trigger || @session.trigger_track?(name)
          @session.route(name, trigger: !!trigger)
        end
        @session.route(name, to: to || :keep, send: send) if to || send

        tr = nil
        patch = Arrangement.counted(patch) if patch
        @mutex.synchronize {
          old = @tracks[name]
          tr = @tracks[name] = Track.new(name: name, patch: patch, graph: graph, q: q, fade: fade, clip: old&.clip, lead: lead, nudge: nudge, ahead: 0r, lead_max: lead_max, capped: false, clock: clock, clocked: nil, trigger: !!trigger)
        }
        set_ahead(tr, graph) if graph || !lead.is_a?(Length::Attack)
        refresh_monitor(tr)
        name
      end

      # +patch+ (a track's patch block) counting its top-level recorded
      # calls while it builds (GraphNode::Recipe.counting), so a literal in
      # the graph it built can be named by where its call was made and
      # bound to a knob (LiteralBinding).  A block like the patch: arity,
      # parameters, lambda?, and source location are the patch's.
      def self.counted(patch)
        return patch if patch.respond_to?(:unbound_patch) || patch.respond_to?(:counted_patch)
        wrapped = proc { |*a, **kw, &b| GraphNode::Recipe.counting { kw.empty? ? patch.call(*a, &b) : patch.call(*a, **kw, &b) } }
        wrapped.define_singleton_method(:arity) { patch.arity }
        wrapped.define_singleton_method(:parameters) { |**k| patch.parameters(**k) }
        wrapped.define_singleton_method(:lambda?) { patch.lambda? }
        wrapped.define_singleton_method(:source_location) { patch.source_location }
        wrapped.define_singleton_method(:counted_patch) { patch }
        # (writers that wrap the user's block themselves, e.g. a set
        # document's, run it in #patch_context)
        wrapped.define_singleton_method(:patch_block) { patch }
        wrapped.define_singleton_method(:patch_context) { |&blk| GraphNode::Recipe.counting(&blk) }
        wrapped
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
          if KEY_VALUES.include?(k)
            check_key_value(name, k, v) or return nil
            next
          end
          kind = @session.names.kind(k)
          if kind == :knob || control_value?(k, v)
            check_knob_value(name, k, v) or return nil
            next
          end
          if kind.nil? && (why = @mutex.synchronize { @failed_tracks[k] })
            # (ux-fix-1: the scene was accepted, then `go` failed without
            # saying why)
            return MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect} names #{k.inspect}, which isn't a track: #{why}; fix the track, then define the scene"))
          end
          next if kind.nil? || kind == :track
          MB::Sound.live_error(ArgumentError.new("Scene #{name.inspect}: #{k.inspect} is a #{kind}, not a track or knob")) or return nil
        end

        # Each track's patch built with the scene's clip for it (see
        # PatchCheck), once per patch and clip
        values.each do |k, v|
          tr = @mutex.synchronize { @tracks[k] }
          next unless tr&.patch? && v.respond_to?(:events)
          seen = @mutex.synchronize { ((@patch_checked ||= {}.compare_by_identity)[tr.patch] ||= {}.compare_by_identity) }
          next if seen[v]
          check_patch(k, tr.patch, v, what: "scene #{name.inspect}, track #{k.inspect}") or return nil
          @mutex.synchronize { seen[v] = true }
        end

        @mutex.synchronize {
          @scenes[name] = Scene.new(name: name, values: values.freeze, q: q, fade: fade, others: others, block: block)
        }
        note_scene_slots(values)
        name
      end

      # Remembers that track +name+'s definition failed with +error+ (a
      # PatchError), so scenes naming it say why (see #scene, #go).
      # Returns nil.
      def note_failed_track(name, error)
        return nil if error.nil?

        why = "track #{name.inspect} wasn't defined: its patch raised #{error.original&.class&.name || 'an error'}"
        where = error.message[/ \(at ([^,]+),/, 1]
        why += " at #{where}" if where
        @mutex.synchronize { @failed_tracks[name] = why unless @tracks.key?(name) }
        nil
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

        knob_values = sc.values.select { |k, v| KEY_VALUES.include?(k) || @session.names.kind(k) == :knob || control_value?(k, v) }
        unknown = sc.values.keys - tracks.keys - knob_values.keys
        unless unknown.empty?
          why = @mutex.synchronize { unknown.filter_map { |u| "#{u.inspect}: #{@failed_tracks[u]}" if @failed_tracks[u] } }
          names = tracks.keys
          hint = unknown.length == 1 ? Form.suggest(unknown.first, names) : ''
          return MB::Sound.live_error(ArgumentError.new(
            "Scene #{name.inspect} names #{unknown.map(&:inspect).join(', ')}, which #{unknown.length == 1 ? 'is not a track or knob' : 'are not tracks or knobs'}" \
            "#{" (#{why.join('; ')})" unless why.empty?}#{" (tracks: #{names.map(&:inspect).join(', ')})" if why.empty? && !names.empty?}#{hint}"
          ))
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
            # (a trigger track given a number: its level turns, the line plays on)
            value = knob_values.key?(tr.name) ? :keep : sc.values.key?(tr.name) ? sc.values[tr.name] : (sc.others == :keep ? :keep : :off)
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
          arm = arms[tr.name]
          state += arm.monitoring? ? ', armed' : ', armed (no monitor)' if arm
          state = "trigger, #{state}" if tr.trigger
          what = tr.patch? ? (tr.clip ? name_of(tr.clip) : 'no clip') : 'graph'
          lead = tr.ahead && !tr.ahead.zero? ? " #{tr.ahead > 0 ? 'ahead' : 'behind'} #{MB::M.sigfigs((tr.ahead.abs / @session.transport.whole_notes_per_second * 1000).to_f, 3)} ms" : ''
          lead += ' (attack capped)' if tr.capped
          "#{pair(:q, (tr.q || @quant).inspect)} #{what}#{lead} (#{state})"
        }
      end

      # A listing of the scenes: name => "pad:chords_a bass:bass_a", with
      # the current scene marked.
      def scene_info
        scenes.transform_values { |sc|
          parts = sc.values.map { |k, v| pair(k, name_of(v)) }
          parts << 'others:keep' if sc.others == :keep
          parts << pair(:q, sc.q.inspect) if sc.q
          parts << '(block)' if sc.block
          "#{sc.name == @current_scene ? '▶ ' : ''}#{parts.join(' ')}"
        }
      end

      # The Set state for undo (see Session#note_undo_extra).
      def undo_state
        @mutex.synchronize { { clips: @tracks.transform_values(&:clip), patches: @tracks.transform_values(&:patch), scene: @current_scene, arms: (@arms || {}).dup } }
      end

      # Puts the Set state back (called by Session undo and redo).
      def restore_undo_state(state)
        @mutex.synchronize {
          state[:clips].each { |n, c| @tracks[n].clip = c if @tracks[n] }
          # (a bound literal's undo: the patch before it; see LiteralBinding)
          state[:patches]&.each { |n, pt| @tracks[n].patch = pt if @tracks[n] && pt }
          @current_scene = state[:scene]
          @arms = state[:arms].dup if state[:arms]
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

      # How much of each track #warm_up plays (bars).
      WARM_UP_BARS = 1/2r

      # Builds every patch track's graph for each clip the scenes give it
      # (and the clip it plays now) in a throwaway Session, and plays it
      # there for WARM_UP_BARS, so YJIT has compiled the code that builds
      # and renders it before a scene change needs it.  With YJIT, the
      # first build of a patch costs 5-20x a later one (night_bus_flow's
      # pluck: ~100 ms, then ~25 ms; ~35 ms every time without YJIT), and
      # a graph's first buffers compile its nodes' code on the render
      # thread (15-60 ms at a scene change, dropouts at 128 frames).
      #
      # The throwaway Session (a "sandbox") has its own transport (the
      # session's tempo and meter) and copies of the session's knobs, at
      # their values, so a patch's knob(:cut) reads the copy; it is made
      # current while the patch runs.  A patch that reaches nodes made
      # outside it (a node captured by its block, shared with live graphs
      # or other tracks) would have them advanced by the sandbox, so each
      # graph is built twice and played only if the two builds share no
      # node; otherwise it is only built (+result+ says :built).  The root
      # random generator is put back as it was (synths draw their seeds
      # from it), and nothing is added to the session, so renders and takes
      # play the same.  Only while the session is idle (nothing playing or
      # queued): a scene built on the scheduler thread meanwhile would draw
      # its seeds from the warm-up's generator (MB::Sound.with_seed swaps
      # the root generator for every thread); otherwise
      # MB::Sound.live_error.
      #
      # +tracks+ limits it to some track names.  Pairs of track and clip
      # already warmed are skipped unless +again+; +play: false+ only
      # builds.  With a +form:+ (a Form), the tracks are built (twice, to
      # find the self-contained ones) but not played on their own: #rehearse
      # then plays the form's transitions with them (#rehearsal is the
      # number of sections it played).  Returns a Hash of track name =>
      # [milliseconds, :played or :built].  Called by #play_form for a
      # realtime session with YJIT (see #play_form's +warm_up:+); console:
      # `warm_up(tracks: true)`.
      def warm_up(*tracks, again: false, play: true, form: nil)
        unless @session.idle?
          return MB::Sound.live_error(RuntimeError.new('warm_up builds the tracks before anything plays (a scene built meanwhile could draw other random seeds)'))
        end

        chosen = self.tracks.values.select { |tr| tr.patch? && (tracks.empty? || tracks.include?(tr.name)) }
        values = Hash.new { |h, k| h[k] = [] }
        scenes.each_value do |sc|
          sc.values.each { |k, v| values[k] << v if v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit) }
        end

        @warmed ||= Hash.new { |h, k| h[k] = {}.compare_by_identity }
        @exercise_skipped = []
        result = {}
        MB::Sound.with_seed(0) do
          chosen.each do |tr|
            clips = ([tr.clip].compact + values[tr.name]).uniq(&:object_id)
            warmed = @mutex.synchronize { @warmed[tr.name] }
            clips.reject! { |c| warmed[c] && warmed[c].equal?(tr.patch) } unless again
            next if clips.empty?

            t0 = MB::U.clock_now
            how = clips.map { |c|
              done = warm_build(tr, c, play: play && !form, check: play)
              @mutex.synchronize { warmed[c] = tr.patch } if done
              done
            }
            # (#rehearse plays only tracks whose every build was played)
            @mutex.synchronize { @rehearsable[tr.name] = how.all?(:played) ? tr.patch : false } if play
            # The rehearsal's short sections never reach a voice's second
            # note: an exercise does (see #warm_exercise)
            if play && form && how.all?(:played) && warm_exercise(tr, clips[0]) == false
              @exercise_skipped << tr.name
            end
            result[tr.name] = [((MB::U.clock_now - t0) * 1000).round(1), how.include?(:built) ? :built : :played]
          end
        end
        @rehearsal = play && form ? rehearse(form) : nil
        # The warm-up's garbage collected now, before anything plays, which
        # also puts off the next major collection (they stop every thread,
        # the render thread too)
        GC.start if form && !result.empty?
        result
      end

      # The number of sections the last #warm_up with a +form:+ rehearsed
      # (see #rehearse), or nil.
      attr_reader :rehearsal

      # The names of the tracks whose exercise the last #warm_up skipped
      # because their patch raised on it (see #warm_exercise); #play_form's
      # warm-up line names them.
      attr_reader :exercise_skipped

      # Each section #rehearse plays lasts the fewest sixteenth notes that
      # hold this many buffers, so code that runs once a buffer is called
      # often enough for YJIT to compile it (MB::Sound::JIT::CALL_THRESHOLD calls;
      # Ruby's default 30 with YJIT started by Ruby's own options).
      REHEARSAL_BUFFERS = 48

      # The most passes of a section #rehearse plays.
      REHEARSAL_PASSES = 2

      # Rehearses +form+'s transitions in a sandbox Session (see #warm_up)
      # at the session's buffer size, so YJIT has compiled what a scene
      # change runs (changes landing, swaps, fades, ring-outs, scheduled
      # blocks, the form's own bookkeeping, players' first buffers, the
      # master and bus chains) before the live form needs it.  Without it,
      # each transition compiled 10-75 ms of new code on the render thread
      # (memory_card at 128 frames: 435 ms in all; scene-jit-1).
      #
      # The sandbox gets the session's master chain, buses, routes, clocks,
      # knobs, the tracks #warm_up played (tracks only built, or graph
      # tracks, are left out of it and of the scenes), and the scenes,
      # and plays a copy of the form straight through (gotos not taken,
      # the first option of each pick), with every section a few
      # sixteenth notes long (see REHEARSAL_BUFFERS) and at most
      # REHEARSAL_PASSES passes, launching at the sections' starts.  Seeds are restored as by
      # #warm_up; nothing changes in the session.  Only while the session
      # is idle.  Returns the number of sections played, or nil if there
      # was nothing to play (an error stops the rehearsal with a warning;
      # the form plays anyway).
      def rehearse(form = last_form)
        return nil unless form
        unless @session.idle?
          return MB::Sound.live_error(RuntimeError.new('rehearse plays the form before anything plays (a scene built meanwhile could draw other random seeds)'))
        end

        names = @mutex.synchronize { @tracks.select { |n, tr| tr.patch? && @rehearsable[n].equal?(tr.patch) }.keys }
        return nil if names.empty?

        rehearse_names(form, names)
      end

      protected

      # Starts +form+ at LaunchPoint +point+ with chance seed +seed+ (see
      # #play_form, which warms up first).  Returns the Form::Playback.
      def launch_form(form, point, seed)
        pb = Form::Playback.new(self, form, seed: seed)
        time = @session.send(:launch_time, point, [])
        old = @mutex.synchronize { prev = @playback; @playback = pb; prev }
        old&.stop
        pb.start(time)
        @session.ensure_running
        pb
      end

      # Takes copies of +tracks+ (Track structs) and +scenes+ for a
      # rehearsal sandbox's Arrangement (see #rehearse).
      def adopt_rehearsal(tracks, scenes, quant)
        tracks.each_key { |n| @session.names.claim(n, :track) }
        @mutex.synchronize {
          @tracks = tracks
          @scenes = scenes
          @quant = quant
        }
      end

      private

      # (#rehearse after its checks) Plays the form's copy, then its first
      # section again in a new sandbox: the song's start, where every
      # track and the master chain start at once, compiled 30-60 ms more
      # in the first live buffer after one pass (memory_card: 62 -> 24 ms
      # at 512 frames for ~0.1 s more).  Returns the sections the first
      # pass played, or nil after an error (warned).
      def rehearse_names(form, names)
        steps = nil
        MB::Sound.with_seed(0) do
          steps = rehearse_pass(names) { |section, bar_length| rehearsal_form(form, section, bar_length) }
          first = form.steps.first[0]
          rehearse_pass(names) { |section, bar_length|
            rehearsal_form(Form.new(sections: form.sections, order: [Form::Play.new(name: first, times: 1)]), section, bar_length)
          }
        end
        steps
      rescue => e
        warn "warm_up: the form's rehearsal stopped (#{e.class}: #{e.message})"
        nil
      end

      # One rehearsal in a new sandbox: the block gets a section length
      # (see REHEARSAL_BUFFERS) and the bar length, and returns the form
      # to play.  Returns the number of sections played.
      def rehearse_pass(names)
        box = warm_sandbox
        t = box.transport
        n16 = (1/16r / t.whole_notes_per_second * box.sample_rate).to_f
        section = 1.n16 * [(REHEARSAL_BUFFERS * box.buffer_size / n16).ceil, 1].max
        short = yield(section, t.bar_length)
        steps = short.steps.sum { |_, times| times }
        Session.with_context(session: box) {
          rehearsal_setup(box, names, section)
          box.arrangement.launch_form(short, LaunchPoint::NONE, 0)
        }
        frames = ((steps + 1/2r) * section.to_r / t.whole_notes_per_second * box.sample_rate).to_f
        (frames / box.buffer_size).ceil.times { box.process_buffer }
        steps
      ensure
        box&.close
      end

      # A copy of +form+ for #rehearse: its straight order, every section
      # +length+ long (a Duration; fills half that, phrase fills every
      # other section, counting +bar_length+ whole notes a bar), at most
      # REHEARSAL_PASSES passes.
      def rehearsal_form(form, length, bar_length)
        half = Sequence::Duration.new(length.to_r / 2)
        sections = form.sections.transform_values { |sec| sec.with(length: length, fill: sec.fill&.with(length: half)) }
        order = form.steps.map { |name, times| Form::Play.new(name: name, times: [times, REHEARSAL_PASSES].min) }
        fills = form.phrase_fills.map { |f| f.with(every: 2 * length.to_r / bar_length, length: half) }
        Form.new(sections: sections, order: order, phrase_fills: fills)
      end

      # Gives sandbox +box+ (current) the session's master chain, buses,
      # routes, and clocks, and the tracks named +names+ with the scenes
      # (other tracks left out of them), launching on multiples of
      # +length+ (a section's), for #rehearse.
      def rehearsal_setup(box, names, length)
        s = @session
        box.master(s.master_preset, &s.master_block) if s.master_preset || s.master_block

        defs = s.bus_definitions
        until defs.empty?
          ready = defs.select { |_, (_, to, _)| to == :master || box.bus_definitions.key?(to) }
          break if ready.empty?
          ready.each { |name, (block, to, desc)| box.bus(name, to: to, description: desc, &block) }
          defs = defs.except(*ready.keys)
        end

        s.clocks.each do |name, c|
          box.define_clock(name, c.base, speed: c.speed.is_a?(Numeric) || c.speed.is_a?(Symbol) ? c.speed : 1)
        end

        tracks = @mutex.synchronize { @tracks.slice(*names).transform_values { |tr| tr.dup.tap { |c| c.q = nil } } }
        routes = s.routes
        tracks.each_key do |n|
          r = routes[n] or next
          if r[:trigger]
            box.route(n, trigger: true)
          else
            sends = r[:send].select { |b, v| v.is_a?(Numeric) && box.bus_definitions.key?(b) }
            to = r[:to] == :master || box.bus_definitions.key?(r[:to]) ? r[:to] : :master
            box.route(n, to: to, send: sends.empty? ? nil : sends)
          end
        end

        others = @mutex.synchronize { @tracks.keys } - names
        scenes = self.scenes.transform_values { |sc| sc.dup.tap { |c| c.values = sc.values.except(*others).freeze; c.q = nil } }
        box.arrangement.adopt_rehearsal(tracks, scenes, length)
      end

      # Builds +tr+'s patch with +clip+ in sandbox Sessions and plays it
      # there if it is self-contained (see #warm_up).  Returns :played,
      # :built, or nil if the patch raised.
      def warm_build(tr, clip, play:, check: play)
        boxes = []
        graphs = (check ? 2 : 1).times.map {
          box = warm_sandbox
          boxes << box
          Session.with_context(session: box) { tr.patch.call(clip) }
        }

        contained = check && (second = warm_nodes(graphs[1])) && warm_nodes(graphs[0]).each_key.none? { |n| second.include?(n) }
        box = boxes[0]
        box.add(graphs[0], on: :now)
        if play && contained
          bar = (box.transport.bar_length / box.transport.whole_notes_per_second * box.sample_rate).to_f
          (bar * WARM_UP_BARS / box.buffer_size).ceil.times { box.process_buffer }
        end
        contained ? :played : :built
      rescue => e
        warn "warm_up: track #{tr.name.inspect} with #{name_of(clip)} raised #{e.class}: #{e.message}"
        nil
      ensure
        boxes&.each(&:close)
      end

      # Notes per round, rounds, and the step between rounds (whole notes)
      # of #warm_exercise.
      EXERCISE_NOTES = 8
      EXERCISE_ROUNDS = 6
      EXERCISE_STEP = 1/32r

      # Plays self-contained track +tr+'s patch alone in a sandbox (see
      # #warm_build) with an exercise made from +clip+'s notes: rounds of
      # every note (up to EXERCISE_NOTES) an EXERCISE_STEP apart, each held
      # three steps, at alternating velocities, so voices are reused,
      # re-struck on held keys, stolen, and released within half a bar.
      # #rehearse plays each section a few sixteenths long, so a synth
      # there plays only its first notes, and its second notes compiled
      # on the render thread live (memory_card's pad at 128 frames: 45 ms
      # in bar 2, phase jumps of reused voices; 18 ms in bar 3, stealing;
      # alloc-2).  Kits (a Sequence::Kit) and clips without notes are
      # skipped (nil), and a patch that can't take the exercise is skipped
      # without a warning (false; it's only a warm-up, and #play_form's
      # warm-up line names it).  Returns true if it played.
      def warm_exercise(tr, clip)
        return nil unless clip.is_a?(Sequence::Clip)
        values = clip.values.first(EXERCISE_NOTES)
        return nil if values.empty?

        events = []
        EXERCISE_ROUNDS.times do |r|
          values.each do |v|
            events << Sequence::Event.new(start: r * EXERCISE_STEP, length: 3 * EXERCISE_STEP, value: v, velocity: r.even? ? 1.0 : 0.5)
          end
        end
        exercise = Sequence::Clip.new(events)

        box = warm_sandbox
        graph = Session.with_context(session: box) { tr.patch.call(exercise) }
        box.add(graph, on: :now)
        bar = (box.transport.bar_length / box.transport.whole_notes_per_second * box.sample_rate).to_f
        (bar * WARM_UP_BARS / box.buffer_size).ceil.times { box.process_buffer }
        true
      rescue StandardError
        false
      ensure
        box&.close
      end

      # The nodes of +graph+ (a Hash of node => true compared by identity;
      # numbers in the graph's sources left out), for #warm_build.
      def warm_nodes(graph)
        set = {}.compare_by_identity
        @session.send(:to_nodes, graph).each { |o| [o, *o.graph].each { |n| set[n] = true unless n.is_a?(Numeric) } }
        set
      end

      # A throwaway Session for #warm_build: the session's tempo, meter,
      # channels, rate, and buffer size, and copies of its knobs.
      def warm_sandbox
        t = @session.transport
        transport = Sequence::Transport.new(bpm: t.bpm, bar_length: t.bar_length)
        channels = @session.instance_variable_get(:@channels)
        output = NullOutput.new(channels: channels, sample_rate: @session.sample_rate, buffer_size: @session.buffer_size, sleep: false)
        box = Session.new(output: output, transport: transport, channels: channels, buffer_size: @session.buffer_size, realtime: false, raise_errors: true, master_gain: 1)
        @session.knobs.each do |name, k|
          sp = k.spec
          box.knob(name, k.value, range: sp.range, curve: sp.curve, unit: sp.unit, takeover: sp.takeover, smooth: sp.smooth)
        end
        box
      end

      # "key:text" for the listings, or "key: :sym" when +text+ is a
      # Symbol's inspect (2026-10-12: `pad: :on` was listed as "pad::on").
      def pair(key, text)
        text.start_with?(':') ? "#{key}: #{text}" : "#{key}:#{text}"
      end

      # Turns knob +name+ to a scene's or section's +value+ at +time+: a
      # number, a node or knob name to follow, or an Array of a value and
      # turn options (`[8000, over: 2.bars, curve: :smooth]`).
      def turn_knob(name, value, time)
        return change_key_value(name, value, time) if KEY_VALUES.include?(name)
        v, options = knob_value(value)
        @session.turn(name, v, start_time: time, **options)
      end

      # True if scene or section value +value+ for +name+ turns the
      # primary control of +name+'s owner (Session::Knobs#control_name:
      # `pump: 0` is the trigger track :pump's on/off level) rather than
      # giving the track a clip: a number, or [number, over: ...].
      def control_value?(name, value)
        return false unless @session.primary_control(name)
        v = value.is_a?(Array) ? value[0] : value
        v.is_a?(Numeric)
      end

      # Splits a scene's knob value into the value and turn options.
      def knob_value(value)
        return [value, {}] unless value.is_a?(Array)
        v, options = value
        [v, (options || {}).slice(:over, :curve, :smooth, :from)]
      end

      # Scene and section values that change the session key (see
      # KeyMethods): `key: :d`, `key: [:a, :minor]`, `mode: :dorian`.
      KEY_VALUES = [:key, :mode].freeze

      # The root and mode of a scene's (or section's) key value.
      def key_value(name, value)
        if name == :mode
          [nil, value]
        elsif value.is_a?(Array)
          value
        elsif MusicalKey.mode_name?(value)
          [nil, value]
        else
          [value, nil]
        end
      end

      # Changes the session key at +time+ (a scene's or section's key:
      # or mode: value).
      def change_key_value(name, value, time)
        root, mode = key_value(name, value)
        @session.change_key(root: root, mode: mode, start_time: time)
      end

      # Checks a scene's (or section's) key: or mode: value; false (after
      # live_error) if it can't be used.
      def check_key_value(owner, name, value)
        root, mode = key_value(name, value)
        raise ArgumentError, 'empty' if root.nil? && mode.nil?
        MusicalKey.parse_root(root) unless root.nil?
        MusicalKey.check_mode(mode) unless mode.nil?
        true
      rescue ArgumentError => e
        !!MB::Sound.live_error(ArgumentError.new("#{owner.inspect}: #{name}: takes a root (:d), a mode (:dorian), or [root, mode] (got #{value.inspect}: #{e.message})"))
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
      def set_track(tr, value, time, fade:, stop: :ring, slot: true)
        change = change_track(tr, value, time, fade: fade, stop: stop)
        # (the clip matrix: which clip each change plays; see ClipMatrix)
        clip = value == :on || value == true ? tr.clip : value
        note_launch(tr.name, change, slot ? clip : nil) if change && !TRACK_STATES.include?(clip)
        change
      end

      # (#set_track without the clip matrix's bookkeeping)
      def change_track(tr, value, time, fade:, stop: :ring)
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
          start_track(tr, tr.clocked_clip(tr.clip), musical, fade)

        else
          check_clip(tr, value)
          value = tr.clocked_clip(value)
          if playing && tr.clip.equal?(value)
            nil
          elsif playing && tr.patch? && (tr.clip.nil? || new_rows?(tr.clip, value) || !swappable?(tr, value))
            start_track(tr, value, musical, fade)
          elsif playing && tr.patch?
            begin
              @session.swap(tr.name, { tr.clip => silence_dropped_rows(tr.clip, value) }, start_time: time)
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

      # Computes track +tr+'s #ahead (for an attack lead, from +graph+'s
      # envelopes) and gives it to +graph+'s clip sources.
      def set_ahead(tr, graph)
        capped = false
        if tr.lead.is_a?(Length::Attack)
          lead = whole_notes(tr.lead.of(attack_lead(graph)))
          cap = whole_notes(tr.lead_max || ATTACK_LEAD_MAX)
          capped = lead > cap
          lead = cap if capped
        else
          lead = whole_notes(tr.lead)
        end
        ahead = lead - whole_notes(tr.nudge)
        @mutex.synchronize { tr.ahead = ahead; tr.capped = capped }
        @session.timeline_nodes_in(graph).grep(MIDI::ClipSource).each { |s| s.ahead = ahead } if graph
        ahead
      end

      # The attack time (a Length) of +graph+'s amplitude envelope: the
      # longest attack of envelopes made by amp_env, else of any envelope
      # (0 without envelopes).  A voice envelope with
      # GM2 time scaling (Notes::NoteEnvelope#gm, on by default) has a node
      # for its attack (the time times CC 73's factor), so its time as
      # given counts (CC 73 at its center).
      def attack_lead(graph)
        envs = @session.send(:to_nodes, graph).flat_map { |n| [n, *n.graph] }.grep(MB::Sound::Envelope).uniq
        amp = envs.select { |e| e.preset_name == :amp_env }
        times = (amp.empty? ? envs : amp).filter_map { |e| envelope_attack(e) }
        (times.max || 0).to_f.seconds
      end

      # The attack time in seconds of envelope +env+ (see #attack_lead), or
      # nil if it can't be known before playing (a node).
      def envelope_attack(env)
        t = env.attack_time rescue nil
        return t if t || !env.respond_to?(:base_times)

        base = env.base_times[env.names[0]]
        return nil unless base.is_a?(Numeric) || (base.is_a?(Length) && !(base.respond_to?(:node) && base.node))
        Length.seconds(base, sample_rate: env.sample_rate).to_f
      rescue ArgumentError
        nil
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
        raise ArgumentError, "#{name}: takes bars, a Duration, or a Length#{name == :lead ? ', or :attack / 0.5.attack' : ''} (got #{v.inspect})" unless ok
        raise ArgumentError, "lead_max: must be more than 0 (got #{v.inspect})" if name == :lead_max && v && !(v.is_a?(Numeric) ? v.positive? : v.to_seconds.positive?)
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
          graph = GraphNode::Mixer.with_ring(@session.ring || GraphNode::Mixer.ring_mode) { tr.patch.call(clip) }
          @mutex.synchronize { (@built ||= {})[tr.name] = graph }
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

      # A swap target for Kit +value+ replacing Kit +old+: +value+ with a
      # silent looping row for each row of +old+ it doesn't have, so those
      # rows stop on the swap instead of playing on (swaps match kit rows
      # by name, and a row missing from the new kit was left alone: a dnb
      # drop's kick and snares kept playing through the hats-only
      # breakdown; patches-5, 2026-10-13).  Other values pass through.
      def silence_dropped_rows(old, value)
        return value unless old.is_a?(Sequence::Kit) && value.is_a?(Sequence::Kit)
        dropped = old.rows.keys - value.rows.keys
        return value if dropped.empty?
        Sequence::Kit.new(value.rows.merge(dropped.to_h { |k| [k, MB::Sound.seq(MB::Sound::R).n1.loop] }))
      end

      # False if the graph last built for track +tr+ has a node that can't
      # play clip +value+ by a swap (a node with #plays_clip?, e.g. a drum
      # kit built for another clip's notes or velocity curve; see
      # Drums::Kit#plays_clip?), so the patch is built again for it.
      def swappable?(tr, value)
        graph = @mutex.synchronize { @built&.[](tr.name) }
        return true if graph.nil? || !value.is_a?(Sequence::Clip)

        outputs = graph.respond_to?(:outputs) ? graph.outputs : Array(graph)
        outputs.flat_map { |n| n.is_a?(GraphNode) ? GraphNode.graph(n) : [] }.uniq.all? { |n|
          !n.respond_to?(:plays_clip?) || n.plays_clip?(value)
        }
      end

      def check_clip(tr, value)
        ok = value.is_a?(Sequence::Clip) || value.is_a?(Sequence::Kit) || value.is_a?(Hash)
        raise ArgumentError, "Track #{tr.name.inspect}: give a Clip, a Kit, :on, :off, or :keep (got #{value.class})" unless ok
      end
    end
  end
end
