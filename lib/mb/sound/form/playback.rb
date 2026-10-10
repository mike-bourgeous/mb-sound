module MB
  module Sound
    class Form
      # A Form playing on an Arrangement: launches each section's scene at
      # its start, picks what comes next at each section's commit point,
      # sets fills on the transport's FillMap, and registers section markers
      # (see Session::Markers).  Created by Arrangement#play_form (console:
      # `flow do ... end`).
      #
      # Commit points: what comes after a pass is decided at the start of
      # the section's fill (if it has one), else at the start of its last
      # bar.  Performer controls (#loop!, #onward, #goto, #finish) issued
      # before the commit point change that boundary; issued after it, they
      # change the following one.  The decision is made by a scheduled
      # block that runs a little ahead of time, so a control arriving after
      # the block ran but before the commit point's time re-decides (the
      # fill scene it launched is cancelled, since it hasn't landed yet):
      # the boundary a control applies to depends only on its time, so takes
      # replay the same way.  #skip and #seek leave at the next bar line.
      #
      # Chance in follow actions (Hashes of weights) uses a random number
      # generator seeded from the form's +seed+ and the number of passes
      # played, so a take replays the same choices.
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

        # The most follow actions (Procs and Hashes leading to more of them)
        # resolved for one decision before giving up.
        MAX_FOLLOW_DEPTH = 16

        attr_reader :form, :seed

        # The section playing now, its pass (from 1), and the step index in
        # the play order.
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
          @steps = form.steps
          @lock = Monitor.new
          @history = []
          @looping = false
          @control = nil
          @later = nil
          @committed = false
          @commit_record = nil
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
            first = @steps.first or raise ArgumentError, 'The form has no sections'
            gen = @gen
            schedule(@start_time, 'form start') { begin_pass(0, first[0], 1, @start_time) if gen == @gen }
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

        # A read-only snapshot for follow-action Procs (see State).
        def state
          @lock.synchronize { state_unlocked }
        end

        # What comes next and where (a Decision): the committed choice, or
        # what the form would choose now (open).
        def upcoming
          @lock.synchronize {
            return Decision.new(section: nil, at: @session.stamp(@boundary || @start_time), committed: true) if @ended
            if @committed
              Decision.new(section: @next == :end ? nil : @next[1], at: @session.stamp(@boundary), committed: true)
            else
              preview = decide_unlocked(peek: true)
              name = preview && preview != :end ? preview[1] : nil
              Decision.new(section: name, at: @session.stamp(@boundary || @start_time), committed: false)
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

        # Plays section +name+ next (at the next uncommitted boundary).
        def goto(name)
          check_section(name)
          control(after: :later) { @control = [:goto, name] }
        end

        # Goes to the last section of the play order (the ending) at the
        # next uncommitted boundary.
        def finish
          control(after: :later) { @control = [:goto_index, @steps.length - 1] }
        end

        # Leaves the current section at the next bar line, for the next
        # section in the play order (or +name+).
        def skip(name = nil)
          check_section(name) if name
          @lock.synchronize {
            raise 'The form has ended' if @ended
            now = @session.now
            t = @transport.next_bar_line(now)
            t = @transport.next_bar_line(now + 1/1024r) if t <= (@pass_start || @start_time)
            return upcoming if @boundary && t >= @boundary && !name && !@committed

            control = @control
            cut_short(t)
            @looping = false
            @next = if name
                      goto_unlocked(name)
                    elsif control
                      @control = control
                      decide_unlocked.tap { @control = nil }
                    else
                      follow_unlocked(:next, 0)
                    end
            commit_effects(t)
            upcoming
          }
        end

        # Plays section +name+ from the next bar line (rehearsal: the
        # timeline keeps running).
        def seek(name)
          skip(name)
        end

        # Plays section +name+ next and repeats it (#goto and #loop!).
        def practice(name)
          check_section(name)
          control(after: :later) {
            @control = [:goto, name]
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
            sec = @form.sections[@section]
            times = @steps[@index]&.last || sec.times
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

        def check_section(name)
          raise ArgumentError, "No section #{name.inspect} in the form (sections: #{@form.sections.keys.map(&:inspect).join(', ')})" unless @form.sections.key?(name)
        end

        # Checks that every section has a scene (or scene: false) and that
        # follow actions name sections of the form.
        def check_form
          scenes = @arrangement.scenes
          @form.sections.each_value do |s|
            scene = scene_of(s)
            if scene && !scenes.key?(scene)
              MB::Sound.live_error(ArgumentError.new("Section #{s.name.inspect} launches scene #{scene.inspect}, which isn't defined (define it with scene #{scene.inspect}, ..., or give the section scene: false)"))
            end

            names = case (a = s.next_action)
                    when Hash then a.keys
                    when Symbol then [a]
                    else []
                    end
            bad = names - ACTIONS - @form.sections.keys
            raise ArgumentError, "Section #{s.name.inspect}: next: names #{bad.map(&:inspect).join(', ')}, which #{bad.length == 1 ? 'is not a section' : 'are not sections'} of the form" unless bad.empty?
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

        # Starts pass +pass+ of section +name+ (step +index+) at +time+:
        # launches its scene, sets phrase fills and markers, and schedules
        # its commit point and boundary.  Runs in a scheduled block at
        # +time+.
        def begin_pass(index, name, pass, time)
          @lock.synchronize {
            return if @ended

            sec = @form.sections[name]
            @index = index
            @section = name
            @pass = pass
            @pass_start = time
            @history << name
            @committed = false
            @commit_record = nil
            @next = nil
            if @later
              @later.call
              @later = nil
            end

            @boundary = time + length_from(sec.length, time)
            @session.markers.set(name, kind: :section, pos: time)

            scene = scene_of(sec)
            @arrangement.go(scene, on: :now, fade: sec.fade) if scene && @arrangement.scenes.key?(scene)

            add_phrase_fills(time, @boundary)

            @fill_start = sec.fill ? [time, @boundary - length_before(sec.fill.length, @boundary)].max : nil
            last_bar = @boundary - length_before(1, @boundary)
            @commit_time = @fill_start || [time, last_bar].max

            gen = @gen
            schedule(@commit_time, "#{name} commit") { commit if gen == @gen }
            boundary = @boundary
            schedule(boundary, "#{name} ends") { cross(boundary) if gen == @gen }
          }
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

        # Sets the fill and next-section marker for the decision in @next,
        # recording what it did in @commit_record (so #undo_commit can take
        # it back).  +time+ is the commit point.
        def commit_effects(time)
          @committed = true
          record = { fills: [], first_seq: nil, last_seq: nil }
          sec = @form.sections[@section]
          fill = sec.fill
          leaving = @next == :end || @next[1] != @section || @next[2] == 1

          if fill && @fill_start && @fill_start < @boundary && (fill.on == :pass || leaving)
            fname = fill.name_for(@pass)
            record[:fills] << @transport.fills.add(@fill_start, @boundary, fname, priority: Sequence::FillMap::SECTION, owner: self)
            if @arrangement.scenes.key?(fname)
              record[:set_state] = @arrangement.undo_state
              record[:first_seq] = @session.journal.next_seq
              Session.with_context(session: @session, time: [@fill_start, time].max, source: :set) {
                @arrangement.go(fname, on: :now)
              }
              record[:last_seq] = @session.journal.next_seq
            end
          end

          @session.markers.set(@next[1], kind: :section, pos: @boundary) unless @next == :end
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

        # At a boundary: the next pass, or the end.
        def cross(time)
          nxt = @lock.synchronize {
            commit unless @committed
            @next
          }

          if nxt == :end
            finish_form(time)
          else
            begin_pass(*nxt, time)
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
            bars: @transport.bar_at(@boundary) - @transport.bar_at(@start_time)
          )
        end

        # The next [index, section, pass], or :end.  With +peek+, doesn't
        # draw random numbers or call Procs (for #upcoming).
        def decide_unlocked(peek: false)
          case @control&.first
          when :goto then return goto_unlocked(@control[1])
          when :goto_index then return [@control[1], @steps[@control[1]][0], 1]
          end
          return [@index, @section, @pass + 1] if @looping
          return nil if @section.nil?

          times = @steps[@index] && @steps[@index][0] == @section ? @steps[@index][1] : @form.sections[@section].times
          return [@index, @section, @pass + 1] if @pass < times

          action = @form.sections[@section].next_action
          # A preview can't draw random numbers or call Procs
          return nil if peek && (action.is_a?(Hash) || action.is_a?(Proc))
          follow_unlocked(action, 0)
        end

        # Resolves a follow action to [index, section, pass] or :end.
        def follow_unlocked(action, depth)
          raise ArgumentError, "Follow actions led to more follow actions #{MAX_FOLLOW_DEPTH} times; give one a section name" if depth > MAX_FOLLOW_DEPTH

          case action
          when :next
            i = @index + 1
            i < @steps.length ? [i, @steps[i][0], 1] : :end
          when :again
            [@index, @section, @pass + 1]
          when :end
            :end
          when Symbol
            goto_unlocked(action)
          when Hash
            rng = Random.new(@seed * 1_000_003 + @history.length)
            total = action.values.sum.to_f
            r = rng.rand * total
            pick = action.find { |_, w| (r -= w) < 0 }&.first || action.keys.last
            follow_unlocked(pick, depth + 1)
          when Proc
            follow_unlocked(action.call(state_unlocked), depth + 1)
          else
            raise ArgumentError, "Unknown follow action #{action.inspect}"
          end
        end

        # The next occurrence of section +name+ in the play order after the
        # current step (wrapping around), as [index, name, 1].
        def goto_unlocked(name)
          n = @steps.length
          (1..n).each do |k|
            i = (@index + k) % n
            return [i, name, 1] if @steps[i][0] == name
          end
          [@index, name, 1]
        end
      end
    end
  end
end
