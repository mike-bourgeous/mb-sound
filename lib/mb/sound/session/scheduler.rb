module MB
  module Sound
    class Session
      # Runs blocks at times on a Session's timeline and applies tempo changes
      # at set times.  Created by Session; use Session#schedule, #cancel,
      # #scheduled, and #change_tempo (or ScheduleMethods) instead of using
      # this class directly.
      #
      # Blocks run a little ahead of their time (on a scheduler thread for a
      # realtime session, or inline when rendering; see #lookahead), inside a context (see
      # Session.with_context) where the #bg, #stop, #resume, and #bpm commands
      # are collected and then take effect exactly at the scheduled time.  If
      # a block takes so long that its time has already passed, its commands
      # are skipped with a warning.
      #
      # Schedules follow the timeline, which only moves while something is
      # playing.  A block whose time has already come runs as soon as
      # possible.
      class Scheduler
        # A block scheduled to run at +time+ (whole notes on the timeline),
        # repeating every +period+ whole notes if +period+ is set.
        # With an +epoch+, it runs only while Session#epoch is that number
        # (the timeline between two seeks; see Session::Seeks), so a take's
        # lines run at their time in the right pass over the timeline.
        # With +exact+ (a take replay's console lines; see Take::Replay), a
        # rendering (not realtime) session runs it at the start of the
        # buffer span containing its time, before the span's tempo is read
        # (see #dispatch_exact), like a line typed between two buffers,
        # instead of a lookahead ahead.
        #
        # +owner+ says who scheduled it: :user (ScheduleMethods, at_marker),
        # :form (a song form's own blocks), :take (a take's replayed lines),
        # or :script (a script's end of --bars).  #cancel with no ids
        # cancels :user blocks; #reset everything but :take lines.
        # +label+ is the command for display (e.g. "at_bar 9"), +status+
        # :pending (waiting for its time), :due (handed to the runner),
        # :running, :ran, or :cancelled.
        Entry = Struct.new(:id, :time, :period, :block, :description, :epoch, :owner, :label, :status, :exact, keyword_init: true)

        # A printable handle for a scheduled block, returned by
        # ScheduleMethods#at_bar, #after, #every (and Session#schedule):
        # prints the command and when it runs (e.g. `at_bar 9 runs 9:1`),
        # and #cancel cancels it.
        class Handle
          def initialize(scheduler, entry)
            @scheduler = scheduler
            @entry = entry
          end

          # The schedule id (Session#cancel accepts it too).
          def id
            @entry.id
          end

          # When the block runs, as a description (e.g. "bar 9").
          def description
            @entry.description
          end

          # Who scheduled it: :user, :form, :take, or :script (see Entry).
          def owner
            @entry.owner
          end

          # The command that scheduled it (e.g. "at_bar 9"), or the
          # description.
          def label
            @entry.label || @entry.description
          end

          # :pending, :due (about to run, ahead of its time), :running,
          # :ran, or :cancelled.
          def status
            @entry.status
          end

          def pending?
            [:pending, :due].include?(status)
          end

          def cancelled?
            status == :cancelled
          end

          def ran?
            status == :ran
          end

          # True for blocks that repeat (ScheduleMethods#every).
          def repeating?
            !@entry.period.nil?
          end

          # The timeline position (whole notes) the block runs at next (for
          # a repeating block, the next occurrence not yet handed to the
          # runner), or the last one once it ran or was cancelled.
          def time
            @entry.time
          end

          # The time as a Session::Stamp (prints as bar:beat).
          def stamp
            @scheduler.stamp(@entry.time)
          end

          # Cancels the block (if it hasn't run yet).  Returns self, which
          # then prints as cancelled.
          def cancel
            @scheduler.cancel(self)
            self
          end

          # E.g. "at_bar 9 runs 9:1", "every 4 bars runs next 4:1",
          # "after 2 ran 3:1", "at_bar 9 cancelled".
          def to_s
            case status
            when :pending, :due then "#{label} runs #{repeating? ? 'next ' : ''}#{stamp}"
            when :running then "#{label} running (for #{stamp})"
            when :ran then "#{label} ran #{stamp}"
            when :cancelled then "#{label} cancelled"
            else "#{label} #{status}"
            end
          end

          def inspect
            "#<Schedule #{id}: #{self}>"
          end

          def pretty_print(q)
            q.text(inspect)
          end

          def ==(other)
            other.is_a?(Handle) && other.entry.equal?(@entry)
          end
          alias eql? ==

          def hash
            @entry.object_id.hash
          end

          protected

          attr_reader :entry
        end

        # Raised into a stuck scheduler thread by #reset.
        class Reset < Exception; end # rubocop:disable Lint/InheritException

        # A one-line summary of a #reset report (see
        # Session#reset_scheduler), or nil if it did nothing.
        def self.reset_message(report)
          parts = []
          parts << 'stopped the song form' if report[:form]
          c = report[:cancelled].reject { |h| h.owner == :form } # "stopped the song form" covers those
          unless c.empty?
            labels = c.map(&:label).uniq
            labels = labels.first(5) + ["#{labels.length - 5} more"] if labels.length > 6
            parts << "cancelled #{c.length} scheduled block#{'s' unless c.length == 1} (#{labels.join(', ')})"
          end
          parts << report[:restarted] if report[:restarted]
          parts.empty? ? nil : parts.join('; ')
        end

        # How long (seconds) #reset waits for a running block to finish
        # before it stops the scheduler thread and starts a fresh one.
        RESET_WAIT = 1.0

        # Raised (through MB::Sound.live_error) when a scheduled block
        # finishes after its time (see #lookahead).
        class LateBlock < RuntimeError; end

        # The scheduler thread's Ruby priority: below the render thread, so
        # a long block (building a scene's graphs) gets shorter time slices
        # and the render thread waits less for the GVL between buffers
        # (with RUBY_THREAD_TIMESLICE=10, a busy thread at priority 0 can
        # hold it for 10 ms, several 128-frame buffers; audio_io.md).
        THREAD_PRIORITY = -3

        # How long ahead (bars) blocks run at least: half a bar.
        MIN_LOOKAHEAD = 1/2r

        # The longest lookahead (bars) the adaptive lookahead grows to.
        MAX_LOOKAHEAD = 2

        # The adaptive lookahead (see #lookahead) runs blocks at least this
        # many times their recent slowest run ahead, plus SAFETY_SECONDS.
        SAFETY_FACTOR = 2
        SAFETY_SECONDS = 0.1

        # How many recent block durations the adaptive lookahead remembers.
        RECENT_BLOCKS = 16

        def initialize(session, realtime:, raise_errors:)
          @session = session
          @transport = session.transport
          @realtime = realtime
          @raise_errors = raise_errors

          @entries = {}
          @next_id = 0
          @timed_changes = []
          @mutex = Mutex.new
          @queue = nil
          @thread = nil

          @lookahead = :auto
          @recent = []
          @late = []
          @running = nil
        end

        # How far ahead of their time blocks run: :auto (the default) or a
        # fixed number of bars (a Rational, or a Duration in whole notes as
        # bars of the current meter).  Rendering (not realtime) always runs
        # them half a bar ahead, so renders don't depend on how long blocks
        # take.  :auto runs them MIN_LOOKAHEAD (half a bar) ahead, or
        # SAFETY_FACTOR times the slowest of the last RECENT_BLOCKS blocks
        # plus SAFETY_SECONDS if that is longer (a scene change that builds
        # graphs for 0.4 s gets ~0.9 s), up to MAX_LOOKAHEAD bars.
        #
        # Changes made by a block land at their exact time as long as the
        # block finishes before it.  A block still running at its time
        # (listed in #late) goes through MB::Sound.live_error:
        # - live mode (bin/sound.rb): changes it makes directly after its
        #   time (a form's scene launch) warn and land right away, late; when
        #   it ends, a LateBlock warning, and the commands it collected for
        #   its time (bg, stop, ... inside at_bar) are skipped.
        # - scripts and specs: the first change it makes after its time
        #   raises Session::LateChange before landing (changes made before
        #   its time stay), its collected commands are skipped, and a block
        #   that only finishes late raises LateBlock.  On a realtime
        #   session's scheduler thread the error is printed (raised with
        #   +raise_errors+).
        attr_reader :lookahead

        # See #lookahead.
        def lookahead=(value)
          unless value == :auto || (value.is_a?(Numeric) && value.real? && value > 0) || value.is_a?(Sequence::Duration)
            raise ArgumentError, "Lookahead must be :auto, a positive number of bars, or a Duration (got #{value.inspect})"
          end
          @lookahead = value
        end

        # The lookahead used now, in whole notes (see #lookahead).
        def lookahead_whole_notes
          bar = @transport.bar_length
          min = bar * MIN_LOOKAHEAD
          return min unless @realtime

          case @lookahead
          when Sequence::Duration then return @lookahead.to_r
          when Numeric then return bar * @lookahead.to_r
          end

          slow = @mutex.synchronize { @recent.max } || 0
          wanted = (slow * SAFETY_FACTOR + SAFETY_SECONDS) * @transport.whole_notes_per_second
          MB::M.clamp(wanted.to_r, min, bar * MAX_LOOKAHEAD)
        end

        # Blocks that finished after their time (the newest RECENT_BLOCKS):
        # Hashes with :description, :time (whole notes), :late (seconds),
        # :seconds (how long the block ran).
        def late
          @mutex.synchronize { @late.dup }
        end

        # Durations in seconds of the last RECENT_BLOCKS blocks.
        def recent_durations
          @mutex.synchronize { @recent.dup }
        end

        # See Session#schedule.  Returns a Handle.
        def schedule(time, period: nil, description: nil, epoch: nil, owner: :user, label: nil, exact: false, &block)
          raise ArgumentError, 'Pass a block to schedule' unless block
          raise ArgumentError, "Period must be positive (got #{period.inspect})" if period && period <= 0

          time = time.to_r
          entry = @mutex.synchronize {
            @next_id += 1
            @entries[@next_id] = Entry.new(
              id: @next_id,
              time: time,
              period: period&.to_r,
              block: block,
              description: description || "bar #{@transport.bar_at(time).floor}",
              epoch: epoch,
              owner: owner,
              label: label,
              status: :pending,
              exact: exact && !@realtime
            )
          }
          Handle.new(self, entry)
        end

        # See Session#cancel.  +ids+ are Handles or ids; with none, cancels
        # every :user block.  Returns the Handles cancelled.
        def cancel(*ids)
          entries = @mutex.synchronize {
            list =
              if ids.empty?
                @entries.values.select { |e| e.owner == :user }
              else
                ids.filter_map { |i| @entries[i.is_a?(Handle) ? i.id : i] }
              end
            list.each { |e| cancel_entry(e) }
          }
          entries.map { |e| Handle.new(self, e) }
        end

        # See Session#scheduled: Handles for the blocks that haven't run
        # yet (and repeating ones), soonest first.
        def scheduled
          @mutex.synchronize { @entries.values.sort_by { |e| [e.time, e.id] } }.map { |e| Handle.new(self, e) }
        end

        # A Stamp for timeline position +time+ (for Handle#to_s).
        def stamp(time)
          Stamp.at(time, @transport)
        end

        # Returns true if a scheduled block's time has come.
        def due?
          @mutex.synchronize { @entries.each_value.any? { |e| e.status == :pending && e.time <= @transport.position && (e.epoch.nil? || e.epoch == @session.epoch) } }
        end

        # The scheduler's panic button (see PlaybackMethods#panic and
        # ScheduleMethods#reset_scheduler): cancels every block except a
        # take's replayed lines (+keep+ owners), including blocks handed to
        # the runner ahead of their time, and on a realtime session, if the
        # scheduler thread died or a block has been running for longer than
        # +wait+ seconds more, stops that thread (Thread#raise, then
        # Thread#kill) and starts a fresh one for the blocks still queued.
        # Called from the scheduler thread itself (a scheduled block or a
        # take line), it only cancels.
        #
        # Returns a Hash: :cancelled (the Handles cancelled), :restarted (nil,
        # or what was wrong with the thread).
        def reset(wait: RESET_WAIT, keep: [:take])
          cancelled = @mutex.synchronize {
            @entries.values.reject { |e| keep.include?(e.owner) }.each { |e| cancel_entry(e) }
          }.map { |e| Handle.new(self, e) }
          report = { cancelled: cancelled, restarted: nil }

          thread = @thread
          return report if !@realtime || thread.nil? || thread.equal?(Thread.current)

          unless thread.alive?
            @thread = nil
            start_thread if @queue && !@queue.empty?
            report[:restarted] = 'the scheduler thread had stopped; started a new one'
            return report
          end

          running = @mutex.synchronize { @running }
          return report if running.nil?

          deadline = MB::U.clock_now + wait
          sleep 0.01 while @mutex.synchronize { @running.equal?(running) } && MB::U.clock_now < deadline
          return report unless @mutex.synchronize { @running.equal?(running) }

          entry, started = running
          seconds = MB::U.clock_now - started
          thread.raise(Reset, 'scheduler reset')
          thread.kill unless thread.join(0.2)
          thread.join(0.2)
          @mutex.synchronize {
            @running = nil
            entry.status = :cancelled
          }
          @thread = nil
          start_thread
          report[:restarted] = format('the block for %s had run %.1f s; stopped it and started a new scheduler thread', entry.description, seconds)
          report
        end

        # See Session#change_tempo.
        def change_tempo(bpm, time:)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          at_time(time) { @transport.bpm = bpm }
          bpm
        end

        # See Session#at_time.
        def at_time(time, &action)
          raise ArgumentError, 'Pass a block to run at the time' unless action
          @mutex.synchronize { @timed_changes << [time.to_r, action] }
          nil
        end

        # Applies tempo changes and other timed changes (see #at_time) whose
        # time has come, in time order.  Called by Session at the start of
        # each buffer.
        def apply_timed_changes
          due = @mutex.synchronize {
            now, @timed_changes = @timed_changes.partition { |time, _| time <= @transport.position }
            now
          }
          due.sort_by(&:first).each { |_, action| action.call }
        end

        # Moves repeating entries to their next time at or after +from+ after
        # the timeline jumps.
        def seeked(from)
          @mutex.synchronize {
            @entries.each_value do |e|
              e.time = from + (e.time - from) % e.period if e.period
            end
          }
        end

        # Starts blocks whose time is before +to+ plus half a bar of
        # lookahead while +playing+, or whose time has come while idle.
        def dispatch(from, to, playing:)
          horizon = playing ? to + lookahead_whole_notes : from

          due = @mutex.synchronize {
            list = []
            epoch = @session.epoch
            @entries.values.each do |e|
              next if e.exact || (e.epoch && e.epoch != epoch)
              next unless e.status == :pending
              while e.time <= horizon
                list << [e, e.time]
                break e.status = :due unless e.period
                e.time += e.period
              end
            end
            list
          }

          due.sort_by { |e, time| [time, e.id] }.each do |e, time|
            # Blocks for times still ahead must finish in time; blocks whose
            # time has already come run as soon as possible
            deadline = time > from ? time : nil
            if @realtime
              start_thread
              @queue << [e, time, deadline]
            else
              run(e, time, deadline)
            end
          end
        end

        # Runs the exact entries (see Entry) whose time is before +to+ (or
        # has come), at the start of the span [+from+, +to+), before
        # Session#process_buffer reads the span's tempo.  Returns true if any
        # ran.
        def dispatch_exact(from, to)
          due = @mutex.synchronize {
            epoch = @session.epoch
            list = @entries.values.select { |e| e.exact && e.status == :pending && (e.epoch.nil? || e.epoch == epoch) && (e.time <= from || e.time < to) }
            list.each { |e| e.status = :due }
            list
          }
          due.sort_by { |e| [e.time, e.id] }.each { |e| run(e, e.time, e.time > from ? e.time : nil) }
          !due.empty?
        end

        # Queues +block+ to run on the scheduler thread between scheduled
        # blocks (generator cycles computed ahead, see Generative::Ahead).
        # Returns false without queuing for a session that renders (no
        # scheduler thread) or a closed scheduler.
        def background(&block)
          return false unless @realtime && !@queue&.closed?
          start_thread
          @queue << [:background, block]
          true
        rescue ClosedQueueError
          false
        end

        # Stops the scheduler thread.
        def close
          Generative::Ahead.detach(self)
          @queue&.close
          @thread&.join(5)
        end

        private

        # Marks +entry+ cancelled and drops it (with @mutex held).
        def cancel_entry(entry)
          entry.status = :cancelled
          @entries.delete(entry.id)
        end

        # Runs a scheduled block, collecting its commands and then applying
        # them if the block finished before +deadline+.  Skips blocks
        # cancelled after they were handed over (see #dispatch).
        def run(entry, time, deadline)
          return if @mutex.synchronize {
            next true if entry.status == :cancelled
            entry.status = :running unless entry.period
            false
          }

          started = MB::U.clock_now
          batch = []
          # Changes the block makes directly whose time has passed by then
          # are late (see Changes#check_late)
          old_deadline = Thread.current[:mb_sound_schedule_deadline]
          Thread.current[:mb_sound_schedule_deadline] = deadline && [@session, entry.description]
          begin
            Session.with_context(session: @session, time: time, batch: batch, source: :schedule) do
              entry.block.call
            end
          ensure
            Thread.current[:mb_sound_schedule_deadline] = old_deadline
            note_duration(MB::U.clock_now - started)
          end

          if deadline && (pos = @transport.position) >= deadline
            message = note_late(entry, time, pos, MB::U.clock_now - started)
            message += batch.empty? ? '' : '; its commands were skipped'
            MB::Sound.live_error(LateBlock.new(message))
          else
            # The block's commands are one undo step (see Session#undo)
            Session.with_context(session: @session, time: time, source: :schedule) do
              @session.command(entry.description) { batch.each(&:call) }
            end
          end

        rescue => e
          raise if @raise_errors
          warn "Scheduled block for #{entry.description} raised #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
        ensure
          @mutex.synchronize {
            if !entry.period && entry.status == :running
              entry.status = :ran
              @entries.delete(entry.id)
            end
          }
        end

        # Remembers how long a block ran, for the adaptive lookahead.
        def note_duration(seconds)
          @mutex.synchronize {
            @recent << seconds
            @recent.shift while @recent.length > RECENT_BLOCKS
          }
        end

        # Notes that the block for +entry+ (at +time+) finished after its
        # time (the timeline at +pos+).  Returns a message for LateBlock.
        def note_late(entry, time, pos, seconds)
          late = ((pos - time) / @transport.whole_notes_per_second).to_f
          @mutex.synchronize {
            @late << { description: entry.description, time: time, late: late, seconds: seconds }
            @late.shift while @late.length > RECENT_BLOCKS
          }
          format('Scheduled block for %s ran %.0f ms and finished %.0f ms after its time (lookahead %.2f bars)',
            entry.description, seconds * 1000, late * 1000, (lookahead_whole_notes / @transport.bar_length).to_f)
        end

        # Starts the thread that runs scheduled blocks for a realtime session.
        def start_thread
          return if @thread&.alive?

          @queue ||= Queue.new
          @thread = Thread.new do
            while (item = @queue.pop)
              if item[0] == :background
                run_background(item[1])
                next
              end

              running = [item[0], MB::U.clock_now]
              @mutex.synchronize { @running = running }
              begin
                run(*item)
              ensure
                @mutex.synchronize { @running = nil if @running.equal?(running) }
              end
            end
          rescue Reset
            # #reset stopped a stuck block; a fresh thread takes the queue
          end
          @thread.name = 'MB::Sound::Session scheduler'
          @thread.priority = THREAD_PRIORITY
          Generative::Ahead.attach(self)
        end

        # Runs a background job (see #background), reporting errors.
        def run_background(job)
          job.call
        rescue StandardError => e
          warn "Background job failed on the scheduler thread: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
