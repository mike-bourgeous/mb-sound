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

        # A decision inside the playback: the section that plays next
        # (+section+ at instruction +index+ of the form's program, pass
        # +pass+; nil section for the end), the goto counts after getting
        # there (+counters+, adopted when the pass starts, so a re-decided
        # commit starts from the same counts), and the +labels+ passed.
        Step = Data.define(:index, :section, :pass, :counters, :labels)

        # The most instructions one decision follows before giving up (a
        # loop of gotos and picks that never reaches a section).
        WALK_LIMIT = 10_000

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
          check_form
        end

        # Starts the form at timeline position +time+ (whole notes).
        def start(time)
          @lock.synchronize {
            raise 'This form has already started' if @started
            @started = true
            @start_time = time.to_r
            raise ArgumentError, 'The form has no sections' unless @program.any? { |ins| ins[0] == :play }
            if @start_time <= @session.now
              # Starting now: launch the first section right away (a
              # scheduled block would run a buffer later when idle)
              Session.with_context(session: @session, time: @start_time, source: Session.context&.[](:source) || :set) {
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

        # True while the current section repeats until #onward.
        def looping?
          @looping
        end

        # The sections played so far, one name per pass (frozen copy).
        def history
          @lock.synchronize { @history.dup.freeze }
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
            index, pos = @where[name] || [target[0] == :label ? @form.labels[name] : first_play(name), nil]
            pos ||= score_positions[index]

            drop_pending_pass
            @transport.fills.remove_owner(self, after: pos)
            @looping = false
            @transport.seek(pos)

            step = @program[index][0] == :label ? walk(index) : Step.new(index: index, section: name, pass: 1, counters: @counters, labels: [].freeze)
            Session.with_context(session: @session, time: pos, source: Session.context&.[](:source) || :set) {
              set_label_markers(step.labels, pos)
              if step.section
                @counters = step.counters
                begin_pass(step.index, step.section, 1, pos)
              else
                finish_form(pos)
              end
            }
            Decision.new(section: step.section, at: @session.stamp(pos), committed: true)
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
            Session.with_context(session: @session, time: snap[:pass_start], source: Session.context&.[](:source) || :set) {
              begin_pass(snap[:index], snap[:section], snap[:pass], snap[:pass_start], record: false)
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
            times = @program[@index][2]
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

        def pretty_print(q)
          q.text(inspect)
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
          @session.schedule(time, description: "form: #{what}", &block)
        end

        # The length in whole notes of a section length (a Duration, or bars
        # counted from +from+).
        def length_from(length, from)
          length.is_a?(Sequence::Duration) ? length.to_r : @transport.bars_length(from, length)
        end

        # The length in whole notes of +length+ (a Duration, or bars)
        # ending at +to+.
        def length_before(length, to)
          return length.to_r if length.is_a?(Sequence::Duration)
          to - @transport.bar_position(@transport.bar_at(to) - length.to_r)
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
              len = @form.sections[ins[1]].length
              ins[2].times { pos += length_from(len, pos) }
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
            step = walk(0)
            set_label_markers(step.labels, @start_time)
            @counters = step.counters
            step.section ? begin_pass(step.index, step.section, 1, @start_time) : finish_form(@start_time)
          }
        end

        # Starts pass +pass+ of section +name+ (instruction +index+) at
        # +time+: launches its scene, sets phrase fills and markers, and
        # schedules its commit point and boundary.  Runs in a scheduled
        # block at +time+.  +record+ false leaves the history alone (a pass
        # resumed by undo).
        def begin_pass(index, name, pass, time, record: true)
          @lock.synchronize {
            return if @ended

            sec = @form.sections[name]
            @index = index
            @section = name
            @pass = pass
            @pass_start = time
            @history << name if record
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
            @pass_seqs = first_seq...@session.journal.next_seq

            @boundary = time + length_from(sec.length, time)
            @session.markers.set(name, kind: :section, pos: time)
            @where[name] = [index, time]

            @transport.fills.prune(time - 1) # fills that ended over a whole note ago
            add_phrase_fills(time, @boundary)

            @fill_start = sec.fill ? [time, @boundary - length_before(sec.fill.length, @boundary)].max : nil
            @commit_time = @fill_start || @boundary

            gen = @gen
            schedule(@commit_time, "#{name} commit") { commit if gen == @gen }
            boundary = @boundary
            schedule(boundary, "#{name} ends") { cross(boundary) if gen == @gen }
          }
        end

        # Drops what the form scheduled and launched ahead for the pass
        # playing now (for a seek and its undo): the scheduled blocks, the
        # commit, a scene launch still queued, and a pass whose start the
        # scheduler ran early (it never played, so it leaves the history).
        def drop_pending_pass
          @history.pop if @pass_start && @pass_start >= @transport.position
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
            @where[@next.section] = [@next.index, @boundary]
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
          { index: @index, section: @section, pass: @pass, pass_start: @pass_start, counters: @counters, looping: @looping }.freeze
        end

        # At a boundary: the next pass, or the end.
        def cross(time)
          nxt = @lock.synchronize {
            commit unless @committed
            @prev_snapshot = @section && pass_snapshot
            @counters = @next.counters
            @next
          }

          if nxt.section.nil?
            finish_form(time)
          else
            begin_pass(nxt.index, nxt.section, nxt.pass, time)
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
          case @control&.first
          when :section then return goto_section(@control[1])
          when :label then return walk(@form.labels[@control[1]], peek: peek)
          when :index then return Step.new(index: @control[1], section: @program[@control[1]][1], pass: 1, counters: @counters, labels: [].freeze)
          end
          return nil if @section.nil?
          return Step.new(index: @index, section: @section, pass: @pass + 1, counters: @counters, labels: [].freeze) if @looping && !skip
          return Step.new(index: @index, section: @section, pass: @pass + 1, counters: @counters, labels: [].freeze) if @pass < @program[@index][2] && !skip
          walk(@index + 1, peek: peek)
        end

        # Follows the program from instruction +i+ (through labels, gotos,
        # picks, and jumps) to the next section, returning a Step.  Gotos
        # count in a copy of the counters; chance draws from one generator
        # per decision.
        def walk(i, peek: false)
          counters = @counters.dup
          labels = []
          rng = nil
          WALK_LIMIT.times do
            ins = @program[i]
            if ins.nil?
              return Step.new(index: nil, section: nil, pass: nil, counters: counters.freeze, labels: labels.freeze)
            end

            case ins[0]
            when :play
              return Step.new(index: i, section: ins[1], pass: 1, counters: counters.freeze, labels: labels.freeze)
            when :label
              labels << ins[1]
              i += 1
            when :jump
              i = ins[1]
            when :pick
              options = ins[1]
              if options.length == 1
                i = options[0][1]
              else
                return nil if peek
                rng ||= decision_rng
                i = weighted(options, rng)
              end
            when :goto
              _, target, times = ins
              n = counters[i] || 0
              if times && n >= times
                counters.delete(i) # fell through: the count starts over
                i += 1
                next
              end

              label = case target
                      when Symbol
                        target
                      when Hash
                        return nil if peek
                        rng ||= decision_rng
                        weighted(target, rng)
                      when Proc
                        return nil if peek
                        goto_proc(target)
                      end

              if label.nil? || label == Form::NEXT
                i += 1
              else
                counters[i] = n + 1 if times
                i = @form.labels.fetch(label)
              end
            end
          end
          raise "The flow went #{WALK_LIMIT} steps without reaching a section (gotos and picks with nothing to play?)"
        end

        # The random number generator for one decision.
        def decision_rng
          Random.new(@seed * 1_000_003 + @history.length)
        end

        # Picks a key of +weights+ (pairs of [key, weight] or [weight,
        # value] for picks) by weight.
        def weighted(weights, rng)
          pairs = weights.is_a?(Hash) ? weights.map { |k, w| [w, k] } : weights
          total = pairs.sum(&:first).to_f
          r = rng.rand * total
          pairs.find { |w, _| (r -= w) < 0 }&.last || pairs.last.last
        end

        # Calls a goto Proc, checking that it returns a label or nil.
        def goto_proc(target)
          label = target.call(state_unlocked)
          return label if label.nil? || label == Form::NEXT || @form.labels.key?(label)
          raise ArgumentError, "A goto Proc returned #{label.inspect}; return a label of the form (#{@form.labels.keys.map(&:inspect).join(', ')}) or nil (or :next) to carry on#{Form.suggest(label, @form.labels.keys)}"
        end

        # The next appearance of section +name+ in the program after the
        # current one (wrapping around), as a Step.
        def goto_section(name)
          n = @program.length
          from = @index || -1
          (1..n).each do |k|
            i = (from + k) % n
            ins = @program[i]
            return Step.new(index: i, section: name, pass: 1, counters: @counters, labels: [].freeze) if ins[0] == :play && ins[1] == name
          end
          raise ArgumentError, "No section #{name.inspect} in the form"
        end
      end
    end
  end
end
