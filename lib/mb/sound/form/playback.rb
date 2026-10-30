module MB
  module Sound
    class Form
      # A Form playing on an Arrangement: launches each section's scene at
      # its start, follows the flow's labels, gotos, and picks at each
      # section's commit point, sets fills on the transport's FillMap, and
      # registers section and label markers (see Session::Markers).  Created
      # by Arrangement#play_form (console: `flow do ... end`).
      #
      # Commit points: what comes after a pass (the next pass, or the gotos
      # and picks up to the next section) is decided at the start of the
      # section's fill (if it has one), else at its end (the bar line where
      # the next section starts).  Performer controls (#loop!, #onward,
      # #goto, #finish) issued before the commit point change that
      # boundary; issued after it, they change the following one.  The
      # decision is made by a scheduled block that runs a little ahead of
      # time, so a control arriving after the block ran but before the
      # commit point's time re-decides (the fill scene it launched is
      # cancelled, since it hasn't landed yet): the boundary a control
      # applies to depends only on its time, so takes replay the same way.
      # #skip leaves at the next bar line (or a launch point); seeks move
      # the timeline (see Session#seek and #seek_now).
      #
      # Chance (weighted gotos and picks) uses a random number generator
      # seeded from the form's +seed+ and the number of passes played, so
      # a take replays the same choices, and a re-decided commit draws the
      # same numbers.
      class Playback
        # Where a control or decision lands: the section that plays next
        # (+section+; nil for the end of the form) at timeline position
        # +at+ (a Session::Stamp), and whether it is +committed+.
        Decision = Data.define(:section, :at, :committed) do
          def to_s
            what = if section
                     "next #{section.inspect}"
                   elsif committed
                     'end'
                   else
                     'next ?'
                   end
            "#{what} at #{at}#{committed ? '' : ' (open)'}"
          end

          def inspect
            "#<#{self}>"
          end

          def pretty_print(q)
            q.text(inspect)
          end
        end

        include Walking

        # A decision inside the playback (see Form::Step).
        Step = Form::Step

        attr_reader :form, :seed

        # The section playing now, its pass (from 1), and its instruction
        # index in the form's program.
        attr_reader :section, :pass, :index

        # Timeline positions (whole notes): where the form started, where
        # the current pass started, where it ends, and its commit point.
        attr_reader :start_time, :pass_start, :boundary, :commit_time

        def initialize(arrangement, form, seed:)
          @arrangement = arrangement
          @session = arrangement.session
          @transport = @session.transport
          @form = form
          @seed = Integer(seed)
          @program = form.program
          @lock = Monitor.new
          @history = []
          @played = []
          @counters = {}.freeze
          @where = {}
          @looping = false
          @control = nil
          @later = nil
          @committed = false
          @commit_record = nil
          @pass_seqs = nil
          @next = nil
          @ended = false
          @started = false
          @gen = 0
          @end_at = nil # (#end_at: no section begins at or after it)
          @decision_offset = 0 # (see #decision_count)
          @plan = nil # (see #plan)
          @plan_meters = nil
          @plan_lock = Mutex.new
          @length = nil # (the current pass's length and times)
          @times = nil
          @start_time = nil
          @pass_start = nil
          check_form
        end

        # Starts the form at timeline position +time+ (whole notes).
        def start(time)
          @lock.synchronize {
            raise 'This form has already started' if @started
            @started = true
            @start_time = time.to_r
            raise ArgumentError, 'The form has no sections' unless @program.any? { |ins| ins[0] == :play || ins[0] == :generate }
            if @start_time <= @session.now
              # Starting now: launch the first section right away (a
              # scheduled block would run a buffer later when idle)
              Session.with_context(session: @session, time: @start_time, source: Session.context&.source || :set) {
                begin_first
              }
            else
              gen = @gen
              schedule(@start_time, 'form start') { begin_first if gen == @gen }
            end
          }
          self
        end

        # True once the form has played its end (or was stopped).
        def ended?
          @ended
        end

        # True once #start was called.
        def started?
          @started
        end

        # True while the current section repeats until #onward.
        def looping?
          @looping
        end

        # The sections played so far, one name per pass (frozen copy).
        def history
          @lock.synchronize { @history.dup.freeze }
        end

        # The passes played so far as [section name, length] pairs (the
        # pass's own length: sections may play for different lengths; for
        # take.form), frozen.
        def played
          @lock.synchronize { @played.dup.freeze }
        end

        # A read-only snapshot for goto Procs (see State).
        def state
          @lock.synchronize { state_unlocked }
        end

        # What comes next and where (a Decision): the committed choice, or
        # what the form would choose now (open; a section of nil while the
        # choice depends on chance or a Proc).
        def upcoming
          @lock.synchronize {
            return Decision.new(section: nil, at: @session.stamp(@boundary || @start_time), committed: true) if @ended
            if @committed
              Decision.new(section: @next.section, at: @session.stamp(@boundary), committed: true)
            else
              preview = decide_unlocked(peek: true)
              Decision.new(section: preview&.section, at: @session.stamp(@boundary || @start_time), committed: false)
            end
          }
        end

        # Repeats the current section until #onward (applies at the next
        # uncommitted boundary).  Returns the Decision.
        def loop!
          control { @looping = true }
        end

        # Ends #loop!: the form moves on at the next uncommitted boundary.
        def onward
          control { @looping = false }
        end

        # Goes to +name+ next (at the next uncommitted boundary): a label of
        # the form (the flow carries on from there), or a section (its next
        # appearance in the play order, wrapping around).
        def goto(name)
          target = control_target(name)
          control(after: :later) { @control = target }
        end

        # Goes to the last section of the play order (the ending) at the
        # next uncommitted boundary.
        def finish
          # (a flow of only generate steps has no last section: it ends)
          control(after: :later) { @control = [:index, last_play] }
        end

        # Leaves the current section at the launch point +at+ (a
        # LaunchPoint; the next bar line by default, and never the start of
        # the pass), for what follows it in the flow (or +name+, a section
        # or label as in #goto).  Journaled as a :skip change (not undoable).
        # Returns the Change.
        def skip(name = nil, at: nil, start_time: nil)
          target = name && control_target(name)
          @session.with_render_lock {
            @lock.synchronize {
              raise 'The form has ended' if @ended
              now = @session.now
              point = at || LaunchPoint::NONE
              t = start_time && !point.given? ? start_time.to_r : @session.send(:launch_time, point, [], default: :bar)
              t = @transport.next_bar_line(now + 1/1024r) if t <= (@pass_start || @start_time)
              t = @boundary if @boundary && t >= @boundary && !name && !@committed

              # Journaled for takes and listings, but not an undo step
              c = @session.send(:without_command) { @session.change(:skip, name || :form, t, data: { to: name }) { |_t| } }
              t = c.time if c.time
              next c if @boundary && t >= @boundary && !name && !@committed

              control = @control
              cut_short(t)
              @looping = false
              @control = target || control
              @next = decide_unlocked(skip: true)
              @control = nil
              commit_effects(t)
              c
            }
          }
        end

        # Moves the timeline to +name+ (a section or label of the form) and
        # plays the form from there: where it last started or is set to
        # start next, else where it sits in the form played straight
        # through (gotos not taken, first pick options).  The action of a
        # :seek change (see Session#seek and Session::Seeks), so it runs
        # with the render lock held, on the frame where the seek lands.
        # Returns the Decision (the section that plays there).
        def seek_now(name)
          target = control_target(name)
          @lock.synchronize {
            raise 'The form has ended' if @ended
            index, pos, length = @where[name]
            if index.nil? && target[0] == :section && first_play(name).nil?
              # Only a generate step plays it: where the plan from here
              # (decided as the form would decide) first plays it
              found = find_ahead(name) or raise ArgumentError, "#{name.inspect} doesn't come up in the next #{PLAN_SEARCH} passes of the form"
              return seek_to_pass(*found)
            end
            index ||= target[0] == :label ? @form.labels[name] : first_play(name)
            pos ||= score_positions[index]

            drop_pending_pass
            @transport.fills.remove_owner(self, after: pos)
            @looping = false
            @transport.seek(pos)

            step = case @program[index][0]
                   when :label then walk(index, time: pos)
                   when :generate
                     forced_generate_step(name).then { |st| length ? st.with(length: length) : st }
                   else play_step(index, @counters)
                   end
            Session.with_context(session: @session, time: pos, source: Session.context&.source || :set) {
              set_label_markers(step.labels, pos)
              if step.section
                @counters = step.counters
                begin_pass(step, pos)
              else
                finish_form(pos)
              end
            }
            Decision.new(section: step.section, at: @session.stamp(pos), committed: true)
          }
        end

        # The form's passes for an uninterrupted run from its start (a
        # Form::Plan, kept so later seeks reuse the passes worked out; made
        # again when the meter map changes), or nil before #start.
        def plan
          return nil unless @start_time
          meters = @transport.meters
          @plan_lock.synchronize {
            unless @plan && @plan_meters == meters
              @plan = Plan.new(@form, seed: @seed, transport: @transport, start: @start_time)
              @plan_meters = meters
            end
            @plan
          }
        end

        # Works out the plan up to +target+ (a timeline position in whole
        # notes, or a section only generate steps play) on the calling
        # thread, so a seek there landing later (on the render thread)
        # finds the passes computed (a seek hours into a generated piece
        # walks thousands of passes: ~25 us each).  Session#seek calls it
        # when a seek is issued.
        def prepare_seek(target)
          if target.is_a?(Symbol)
            find_ahead(target) if @form.sections.key?(target) && first_play(target).nil?
          else
            plan&.at(target)
          end
          nil
        end

        # How many passes ahead #seek_now looks for a section only a
        # generate step plays.
        PLAN_SEARCH = 10_000

        # Moves the timeline to +pos+ (whole notes) and plays the form on
        # from the pass playing there in an uninterrupted run of the form
        # from its start (G4: the same decisions, worked out by a
        # Form::Plan, so a seek into a long generated piece plays what the
        # piece plays there; performer controls aren't replayed).  The
        # pass's scene launches at +pos+, mid-section; the pass ends where
        # it would.  The action of a :seek change to a bar or other
        # position (see Session::Seeks).  Returns the Decision.
        def seek_position(pos)
          pos = pos.to_r
          @lock.synchronize {
            raise 'The form has ended' if @ended
            plan = self.plan
            pass = plan.at(pos)
            unless pass
              drop_pending_pass
              @transport.fills.remove_owner(self, after: pos)
              @transport.seek(pos)
              Session.with_context(session: @session, time: pos, source: Session.context&.source || :set) { finish_form(pos) }
              return Decision.new(section: nil, at: @session.stamp(pos), committed: true)
            end
            seek_to_pass(pass, plan.history.first(pass.number), at: pos)
          }
        end

        # What #restore_seek needs to put the form back in the pass playing
        # now (nil if the form has ended or not started).
        def seek_snapshot
          @lock.synchronize {
            next nil if @ended || @section.nil?
            # A pass the scheduler started ahead of time isn't playing yet
            next @prev_snapshot if @pass_start > @transport.position && @prev_snapshot
            pass_snapshot
          }
        end

        # Puts the form back in the pass of +snap+ (see #seek_snapshot),
        # after the timeline moved back into it (undo of a seek).
        def restore_seek(snap)
          @lock.synchronize {
            return if @ended
            drop_pending_pass
            @transport.fills.remove_owner(self, after: snap[:pass_start])
            @counters = snap[:counters]
            @looping = snap[:looping]
            step = Step.new(index: snap[:index], section: snap[:section], pass: snap[:pass], counters: snap[:counters], labels: [].freeze,
                            length: snap[:length], times: snap[:times])
            Session.with_context(session: @session, time: snap[:pass_start], source: Session.context&.source || :set) {
              begin_pass(step, snap[:pass_start], record: false)
            }
          }
        end

        # Plays +name+ (a section or label, as in #goto) next and repeats
        # it (#goto and #loop!).
        def practice(name)
          target = control_target(name)
          control(after: :later) {
            @control = target
            @looping = true
          }
        end

        # Ends the form at timeline position +time+ (whole notes): no section
        # begins at or after it (what is playing keeps playing; an outro or a
        # stop :all at the same point fades or stops it).  Used by outro,
        # stop :all, and a manual go while the flow plays (ui-api-1; the
        # maintainer's `outro in: 2.bars` faded out, then the next section's
        # scene came in).  A time now or earlier stops the form right away.
        # Returns the Stamp where it ends.
        def end_at(time)
          time = time.to_r
          return @session.stamp(time).tap { stop } if time <= @session.now
          @lock.synchronize {
            @end_at = @end_at ? [@end_at, time].min : time
            if @pass_start && @pass_start >= @end_at
              # The scheduler began the next pass ahead of its time (scene
              # builds run early): it never plays
              drop_pending_pass
              @ended = true
            elsif @commit_record && @fill_start && @fill_start >= @end_at
              undo_commit # (a fill launched for after the end)
            end
          }
          @session.stamp(@end_at)
        end

        # The section that plays scene +scene+ for `go` (maintainer,
        # 2026-10-18: "Always forward if present, nearest back if not"): the
        # first section after the current one in the play order (played
        # straight through) whose scene is +scene+, else the nearest one at
        # or before it; nil if no section plays it.  (`go :drop, section:
        # :drop2` picks one by name.)
        def section_for_scene(scene)
          steps = @form.steps.map(&:first)
          plays = ->(n) { (s = @form.sections[n]) && scene_of(s) == scene }
          i = steps.index(@section) || -1
          steps[(i + 1)..].find(&plays) || steps[0..i].reverse.find(&plays)
        end

        # The sections whose scene is +scene+ (play order, each once).
        def sections_for_scene(scene)
          @form.steps.map(&:first).uniq.select { |n| (s = @form.sections[n]) && scene_of(s) == scene }
        end

        # Where #end_at ends the form (whole notes), or nil.
        def ends_at
          @end_at
        end

        # Stops the form: no more sections launch (what is playing keeps
        # playing).  Scheduled blocks are dropped.
        def stop
          @lock.synchronize {
            @gen += 1
            @ended = true
            undo_commit
            @transport.fills.remove_owner(self, after: @session.now)
          }
          self
        end

        def to_s
          @lock.synchronize {
            return 'form (not started)' unless @section || @ended
            return "form ended after #{@history.length} passes" if @ended
            times = @times
            bar_now = (@transport.bar_at(@session.now) - @transport.bar_at(@pass_start)).floor + 1
            bars = (@transport.bar_at(@boundary) - @transport.bar_at(@pass_start))
            bars = bars.denominator == 1 ? bars.to_i : bars.to_f.round(2)
            nxt = upcoming
            "▶ #{@section} pass #{@pass}/#{@looping ? '∞' : times} (bar #{bar_now} of #{bars}), #{nxt}#{@looping ? ', looping' : ''}"
          }
        end

        def inspect
          "#<Form::Playback #{self}>"
        end

        # The console's view (`flow` with no block): where the flow is, its
        # sections in order with the one playing in brackets, and how to
        # steer and end it.
        def show
          if @form.generative?
            # (sections decided as it plays: the last few passes, then more)
            played = @lock.synchronize { @played.last(6) }
            names = played.each_with_index.map { |(name, len), i| t = "#{name} #{Form.ruby_value(len)}"; i == played.length - 1 && !@ended ? "[#{t}]" : t }
            names.unshift('…') if @history.length > played.length
            names << '… (generated as it plays)' unless @ended
          else
            names = @form.steps.map { |name, times| "#{name}#{" x#{times}" if times != 1}" }
            names = @form.steps.each_with_index.map { |(name, _), i| name == @section && !@ended ? "[#{names[i]}]" : names[i] }
          end
          lines = ["flow #{self}#{", ends at #{@session.stamp(@end_at)}" if @end_at && !@ended}"]
          lines << "  #{names.join(' · ')}"
          if @ended
            lines << '  start (or play) plays it again from the start'
          else
            lines << '  steer: loop!  onward  goto :name  skip  practice :name  go :scene (seeks to the next section playing it; section: picks one)'
            lines << '  end:   finish (the ending next)  outro in: 4.bars (fades out, ends the flow)  stop :all'
          end
          lines.join("\n")
        end

        def pretty_print(q)
          q.text(show)
        end

        private

        # Runs a control's +block+ for the next uncommitted boundary.
        # Before the commit point (by time) it applies now, re-deciding a
        # commit that ran early; after it, +after: :later+ controls wait
        # for the following pass, and flag changes (loop!/onward) apply to
        # the following boundary by themselves.
        def control(after: nil, &block)
          @lock.synchronize {
            raise 'The form has ended' if @ended
            now = @session.now

            if !@committed || (@commit_time && now < @commit_time)
              if @committed
                undo_commit
                @committed = false
                block.call
                Session.with_context(session: @session, time: @commit_time, source: :set) { commit }
              else
                block.call
              end
            elsif after == :later
              @later = block
            else
              block.call
            end

            upcoming
          }
        end

        # The control for a goto/skip/practice/seek target: [:label, name]
        # or [:section, name].  Raises with suggestions for other names.
        def control_target(name)
          return [:label, name] if @form.labels.key?(name)
          return [:section, name] if @form.sections.key?(name)
          names = @form.sections.keys + @form.labels.keys
          raise ArgumentError, "No section or label #{name.inspect} in the form (sections: #{@form.sections.keys.map(&:inspect).join(', ')}; labels: #{@form.labels.empty? ? 'none' : @form.labels.keys.map(&:inspect).join(', ')})#{Form.suggest(name, names)}"
        end

        # Checks that every section has a scene (or scene: false).
        def check_form
          scenes = @arrangement.scenes
          @form.sections.each_value do |s|
            scene = scene_of(s)
            if scene && !scenes.key?(scene)
              MB::Sound.live_error(ArgumentError.new("Section #{s.name.inspect} launches scene #{scene.inspect}, which isn't defined (define it with scene #{scene.inspect}, ..., or give the section scene: false)"))
            end
          end
        end

        # The scene a section launches, or nil.
        def scene_of(section)
          return nil if section.scene == false
          section.scene || section.name
        end

        def schedule(time, what, &block)
          @session.schedule(time, description: "form: #{what}", owner: :form, &block)
        end

        # The index of the last section in the program (for #finish).
        def last_play
          @program.rindex { |ins| ins[0] == :play }
        end

        # The index of the first appearance of section +name+.
        def first_play(name)
          @program.index { |ins| ins[0] == :play && ins[1] == name }
        end

        # Instruction index => timeline position with the form played
        # straight through from its start (gotos not taken; instructions in
        # a pick's other options at the pick's position), for #seek.
        def score_positions
          pos = @start_time
          result = {}
          picks = []
          @program.each_with_index do |ins, i|
            while (top = picks.last) && i == top[:finish]
              pos = top[:after] || pos
              picks.pop
            end
            result[i] = pos
            case ins[0]
            when :play
              ins[2].times { pos += length_from(ins[3], pos) }
              # (a generate step's sections are decided as it plays: none
              # counted here)
            when :pick
              picks << { start: pos, finish: ins[2], after: nil }
            when :jump
              top = picks.last
              if top && ins[1] == top[:finish]
                top[:after] ||= pos
                pos = top[:start]
              end
            end
          end
          result
        end

        # Starts the form: follows the flow to its first section.
        def begin_first
          @lock.synchronize {
            return if @ended
            step = walk(0, time: @start_time)
            set_label_markers(step.labels, @start_time)
            @counters = step.counters
            step.section ? begin_pass(step, @start_time) : finish_form(@start_time)
          }
        end

        # Starts the pass of +step+ (a Step: its section, instruction index,
        # pass, length, and times) at +time+: launches its scene, sets
        # phrase fills and markers, and schedules its commit point and
        # boundary.  Runs in a scheduled block at +time+ (or, for a seek
        # into a pass, at the seek's position, after +time+).  +record+
        # false leaves the history alone (a pass resumed by undo).
        def begin_pass(step, time, record: true)
          @lock.synchronize {
            return if @ended

            name = step.section
            index = step.index
            sec = @form.sections[name]
            @index = index
            @section = name
            @pass = step.pass
            @length = step.length
            @times = step.times
            @pass_start = time
            if record
              @history << name
              @played << [name, step.length].freeze
            end
            @committed = false
            @commit_record = nil
            @next = nil
            if @later
              @later.call
              @later = nil
            end

            # The scene first: its block may change the meter (e.g. a 2/4
            # bar), which the section's length in bars counts in
            scene = scene_of(sec)
            first_seq = @session.journal.next_seq
            launch(scene, fade: sec.fade) if scene && @arrangement.scenes.key?(scene)
            # The section's knob values, after its scene's (they win)
            # (a pass a seek enters mid-way turns them where the seek lands)
            turn_at = [time, @session.now].max
            sec.knobs.each do |k, v|
              @session.send(:without_command) { @arrangement.send(:turn_knob, k, v, turn_at) }
            end
            @pass_seqs = first_seq...@session.journal.next_seq

            # (this pass's length: a section may play for different lengths)
            @boundary = time + length_from(@length, time)
            @session.markers.set(name, kind: :section, pos: time)
            @where[name] = [index, time, @length]

            @transport.fills.prune(time - 1) # fills that ended over a whole note ago
            add_phrase_fills(time, @boundary)

            @fill_start = sec.fill ? [time, @boundary - length_before(sec.fill.length, @boundary)].max : nil
            @commit_time = @fill_start || @boundary

            gen = @gen
            schedule(@commit_time, "#{name} commit") { commit if gen == @gen && !(@end_at && @commit_time >= @end_at) }
            boundary = @boundary
            schedule(boundary, "#{name} ends") { cross(boundary) if gen == @gen }
          }
        end

        # The number of passes chance decisions count (seeding each
        # decision's generator): the passes played, plus the difference a
        # seek into a Form::Plan made (the passes an uninterrupted run had
        # played there).
        def decision_count
          @history.length + @decision_offset
        end

        # The pass of an uninterrupted run (a Form::Plan from the form's
        # start) that next plays section +name+ after the current pass, and
        # the names played before it, or nil.
        def find_ahead(name)
          plan = self.plan
          now = [@pass_start || @start_time, @transport.position].max
          from = 0
          from += 1 while (p = plan[from]) && p.start <= now && from < PLAN_SEARCH
          pass = plan.find(name, from: from, limit: PLAN_SEARCH) or return nil
          [pass, plan.history.first(pass.number)]
        end

        # Moves the timeline to +at+ (the pass's start by default) and plays
        # Plan pass +pass+ from there, counting decisions from the passes an
        # uninterrupted run played before it (so the passes after it draw
        # what that run draws; the run's names, +_history+, are for goto
        # Procs, which see what actually played).  Returns the Decision.
        def seek_to_pass(pass, _history, at: nil)
          pos = at || pass.start
          drop_pending_pass
          @transport.fills.remove_owner(self, after: pos)
          @looping = false
          @transport.seek(pos)
          # Decisions count passes as the uninterrupted run did (the history
          # stays what played)
          @decision_offset = pass.number - @history.length
          @counters = pass.counters
          step = Step.new(index: pass.index, section: pass.section, pass: pass.pass, counters: pass.counters, labels: [].freeze,
                          length: pass.length, times: pass.times)
          Session.with_context(session: @session, time: pos, source: Session.context&.source || :set) {
            begin_pass(step, pass.start)
          }
          Decision.new(section: pass.section, at: @session.stamp(pos), committed: true)
        end

        # Drops what the form scheduled and launched ahead for the pass
        # playing now (for a seek and its undo): the scheduled blocks, the
        # commit, a scene launch still queued, and a pass whose start the
        # scheduler ran early (it never played, so it leaves the history).
        def drop_pending_pass
          if @pass_start && @pass_start >= @transport.position
            @history.pop
            @played.pop
          end
          @gen += 1
          undo_commit
          cancel_pass_changes
          skips = @session.queued.select { |e| e.kind == :skip }.map(&:seq)
          @session.cancel_changes(*skips) unless skips.empty?
          @control = nil
          @later = nil
        end

        # Launches scene +name+ now (the context's time).  The form's own
        # launches aren't undo steps (undo is for the performer's commands;
        # a section launch would otherwise be what `undo` takes back).
        def launch(name, fade: nil)
          @session.send(:without_command) { @arrangement.go(name, on: :now, fade: fade) }
        end

        # Cancels the current pass's scene launch if it hasn't landed yet
        # (for #seek).
        def cancel_pass_changes
          return unless @pass_seqs && @pass_seqs.begin < @pass_seqs.end
          seqs = @session.queued.map(&:seq).select { |s| @pass_seqs.cover?(s) }
          @session.cancel_changes(*seqs) unless seqs.empty?
        end

        # Sets :label markers for +labels+ at +pos+ (where the section that
        # follows them starts).
        def set_label_markers(labels, pos)
          labels.each do |l|
            @session.markers.set(l, kind: :label, pos: pos)
            @where[l] = [@form.labels[l], pos]
          end
        end

        # Adds the phrase fills that end inside [+from+, +to+] (counting
        # phrases from +from+).
        def add_phrase_fills(from, to)
          start_bar = @transport.bar_at(from)
          @form.phrase_fills.each do |pf|
            k = 1
            loop do
              phrase_end = @transport.bar_position(start_bar + k * pf.every.to_r)
              break if phrase_end > to
              fill_from = [from, phrase_end - length_before(pf.length, phrase_end)].max
              @transport.fills.add(fill_from, phrase_end, pf.name, priority: pf.every.to_r, layer: pf.layer, owner: self)
              k += 1
            end
          end
        end

        # Decides what follows the current pass and starts its fill.  Runs
        # in a scheduled block at the commit point (or from #control).
        def commit
          @lock.synchronize {
            return if @committed || @ended
            @next = decide_unlocked
            @control = nil
            @committed = true
            commit_effects(@commit_time)
          }
        end

        # Sets the fill and next-section and label markers for the decision
        # in @next, recording what it did in @commit_record (so
        # #undo_commit can take it back).  +time+ is the commit point.
        def commit_effects(time)
          @committed = true
          record = { fills: [], first_seq: nil, last_seq: nil }
          sec = @form.sections[@section]
          fill = sec.fill
          leaving = @next.section.nil? || @next.index != @index || @next.pass == 1

          if fill && @fill_start && @fill_start < @boundary && (fill.on == :pass || leaving)
            fname = fill.name_for(@pass)
            record[:fills] << @transport.fills.add(@fill_start, @boundary, fname, priority: Sequence::FillMap::SECTION, owner: self)
            if @arrangement.scenes.key?(fname)
              record[:set_state] = @arrangement.undo_state
              record[:first_seq] = @session.journal.next_seq
              Session.with_context(session: @session, time: [@fill_start, time].max, source: :set) {
                launch(fname)
              }
              record[:last_seq] = @session.journal.next_seq
            end
          end

          set_label_markers(@next.labels, @boundary)
          if @next.section
            @session.markers.set(@next.section, kind: :section, pos: @boundary)
            @where[@next.section] = [@next.index, @boundary, @next.length]
          end
          @commit_record = record
        end

        # Takes back a commit's fill and fill scene (changes that haven't
        # landed are cancelled).
        def undo_commit
          rec = @commit_record or return
          @transport.fills.remove(*rec[:fills]) unless rec[:fills].empty?
          if rec[:first_seq]
            range = rec[:first_seq]..rec[:last_seq]
            seqs = @session.queued.map(&:seq).select { |s| range.cover?(s) }
            @session.cancel_changes(*seqs) unless seqs.empty?
            @arrangement.restore_undo_state(rec[:set_state])
          end
          @commit_record = nil
        end

        # Moves the current boundary to +t+ (for #skip): drops the commit
        # and the scheduled blocks, and schedules the new boundary.
        def cut_short(t)
          undo_commit
          @gen += 1
          @transport.fills.remove_owner(self, after: t)
          @boundary = t
          @fill_start = nil
          @commit_time = t
          @control = nil
          gen = @gen
          schedule(t, "#{@section} cut short") { cross(t) if gen == @gen }
        end

        # The current pass for #seek_snapshot.
        def pass_snapshot
          { index: @index, section: @section, pass: @pass, pass_start: @pass_start, counters: @counters, looping: @looping,
            length: @length, times: @times }.freeze
        end

        # At a boundary: the next pass, or the end.
        def cross(time)
          if @end_at && time.to_r >= @end_at
            @lock.synchronize {
              @ended = true
              @gen += 1
            }
            return
          end

          nxt = @lock.synchronize {
            commit unless @committed
            @prev_snapshot = @section && pass_snapshot
            @counters = @next.counters
            @next
          }

          if nxt.section.nil?
            finish_form(time)
          else
            begin_pass(nxt, time)
          end
        end

        # Ends the form at +time+: every player rings out (see
        # Session::Tails).
        def finish_form(time)
          @lock.synchronize {
            @ended = true
            @gen += 1
          }
          @session.remove(time: time, ring: true)
          @session.markers.set(:end, kind: :section, pos: time)
        end

        def state_unlocked
          State.new(
            section: @section, pass: @pass, history: @history,
            bars: @boundary ? @transport.bar_at(@boundary) - @transport.bar_at(@start_time) : 0
          )
        end

        # What follows the current pass (a Step; its section is nil for the
        # end).  With +peek+, returns nil instead of drawing random numbers
        # or calling Procs (for #upcoming).  With +skip+, leaves the
        # section even if it has passes left (for #skip).
        def decide_unlocked(peek: false, skip: false)
          time = @commit_time || @start_time
          case @control&.first
          when :section then return goto_section(@control[1])
          when :label then return walk(@form.labels[@control[1]], peek: peek, time: time)
          when :index
            return Step.new(index: nil, section: nil, pass: nil, counters: @counters, labels: [].freeze) if @control[1].nil?
            return play_step(@control[1], @counters)
          end
          return nil if @section.nil?
          again = Step.new(index: @index, section: @section, pass: @pass + 1, counters: @counters, labels: [].freeze, length: @length, times: @times)
          return again if @looping && !skip
          return again if @pass < @times && !skip
          # (a generate step plays its next section, or lets the flow carry on)
          walk(@program[@index][0] == :generate ? @index : @index + 1, peek: peek, time: time)
        end

        # The next appearance of section +name+ in the program after the
        # current one (wrapping around), as a Step.
        def goto_section(name)
          n = @program.length
          from = @index || -1
          (1..n).each do |k|
            i = (from + k) % n
            ins = @program[i]
            return play_step(i, @counters) if ins[0] == :play && ins[1] == name
          end
          # Only a generate step plays it: that step plays it next, and its
          # source carries on from there (a chain from that state)
          forced_generate_step(name) or raise ArgumentError, "No section #{name.inspect} in the form"
        end
      end
    end
  end
end
