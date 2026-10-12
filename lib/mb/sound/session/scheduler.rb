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
        Entry = Struct.new(:id, :time, :period, :block, :description, :epoch, keyword_init: true)

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
        # block finishes before it; a block that finishes late warns (see
        # #late), its own commands collected for its time are skipped, and
        # changes it made directly (a scene launch) land late.
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

        # See Session#schedule.
        def schedule(time, period: nil, description: nil, epoch: nil, &block)
          raise ArgumentError, 'Pass a block to schedule' unless block
          raise ArgumentError, "Period must be positive (got #{period.inspect})" if period && period <= 0

          time = time.to_r
          @mutex.synchronize {
            @next_id += 1
            @entries[@next_id] = Entry.new(
              id: @next_id,
              time: time,
              period: period&.to_r,
              block: block,
              description: description || "bar #{@transport.bar_at(time).floor}",
              epoch: epoch
            )
            @next_id
          }
        end

        # See Session#cancel.
        def cancel(*ids)
          @mutex.synchronize {
            ids = @entries.keys if ids.empty?
            ids.select { |id| @entries.delete(id) }
          }
        end

        # See Session#scheduled.
        def scheduled
          @mutex.synchronize { @entries.transform_values(&:description) }
        end

        # Returns true if a scheduled block's time has come.
        def due?
          @mutex.synchronize { @entries.each_value.any? { |e| e.time <= @transport.position && (e.epoch.nil? || e.epoch == @session.epoch) } }
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
              next if e.epoch && e.epoch != epoch
              while e.time <= horizon
                list << [e, e.time]
                break @entries.delete(e.id) unless e.period
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

        # Stops the scheduler thread.
        def close
          @queue&.close
          @thread&.join(5)
        end

        private

        # Runs a scheduled block, collecting its commands and then applying
        # them if the block finished before +deadline+.
        def run(entry, time, deadline)
          started = MB::U.clock_now
          batch = []
          Session.with_context(session: @session, time: time, batch: batch, source: :schedule) do
            entry.block.call
          end
          note_duration(MB::U.clock_now - started)

          if deadline && (pos = @transport.position) >= deadline
            note_late(entry, time, pos, MB::U.clock_now - started)
            warn "Skipped the commands scheduled for #{entry.description}: the block finished after its time" unless batch.empty?
          else
            # The block's commands are one undo step (see Session#undo)
            Session.with_context(session: @session, time: time, source: :schedule) do
              @session.command(entry.description) { batch.each(&:call) }
            end
          end

        rescue => e
          raise if @raise_errors
          warn "Scheduled block for #{entry.description} raised #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
        end

        # Remembers how long a block ran, for the adaptive lookahead.
        def note_duration(seconds)
          @mutex.synchronize {
            @recent << seconds
            @recent.shift while @recent.length > RECENT_BLOCKS
          }
        end

        # Notes and warns that the block for +entry+ (at +time+) finished
        # after its time (the timeline at +pos+), so changes it made
        # directly landed late.
        def note_late(entry, time, pos, seconds)
          late = ((pos - time) / @transport.whole_notes_per_second).to_f
          @mutex.synchronize {
            @late << { description: entry.description, time: time, late: late, seconds: seconds }
            @late.shift while @late.length > RECENT_BLOCKS
          }
          warn format('Scheduled block for %s ran %.0f ms and finished %.0f ms after its time; its changes landed late (lookahead %.2f bars)',
            entry.description, seconds * 1000, late * 1000, (lookahead_whole_notes / @transport.bar_length).to_f)
        end

        # Starts the thread that runs scheduled blocks for a realtime session.
        def start_thread
          return if @thread&.alive?

          @queue ||= Queue.new
          @thread = Thread.new do
            while (item = @queue.pop)
              run(*item)
            end
          end
          @thread.name = 'MB::Sound::Session scheduler'
          @thread.priority = THREAD_PRIORITY
        end
      end
    end
  end
end
