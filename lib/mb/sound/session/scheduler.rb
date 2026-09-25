module MB
  module Sound
    class Session
      # Runs blocks at times on a Session's timeline and applies tempo changes
      # at set times.  Created by Session; use Session#schedule, #cancel,
      # #scheduled, and #change_tempo (or ScheduleMethods) instead of using
      # this class directly.
      #
      # Blocks run a little ahead of their time (on a scheduler thread for a
      # realtime session, or inline when rendering), inside a context (see
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
        Entry = Struct.new(:id, :time, :period, :block, :description, keyword_init: true)

        def initialize(session, realtime:, raise_errors:)
          @session = session
          @transport = session.transport
          @realtime = realtime
          @raise_errors = raise_errors

          @entries = {}
          @next_id = 0
          @tempo_changes = []
          @mutex = Mutex.new
          @queue = nil
          @thread = nil
        end

        # See Session#schedule.
        def schedule(time, period: nil, description: nil, &block)
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
              description: description || "bar #{(time / @transport.bar_length).floor + 1}"
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
          @mutex.synchronize { @entries.each_value.any? { |e| e.time <= @transport.position } }
        end

        # See Session#change_tempo.
        def change_tempo(bpm, time:)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          @mutex.synchronize { @tempo_changes << [time.to_r, bpm] }
          bpm
        end

        # Applies tempo changes whose time has come.  Called by Session at
        # the start of each buffer.
        def apply_tempo_changes
          due = @mutex.synchronize {
            now, @tempo_changes = @tempo_changes.partition { |time, _| time <= @transport.position }
            now
          }
          due.sort_by(&:first).each { |_, bpm| @transport.bpm = bpm }
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
          horizon = playing ? to + @transport.bar_length / 2 : from

          due = @mutex.synchronize {
            list = []
            @entries.values.each do |e|
              while e.time <= horizon
                list << [e, e.time]
                break @entries.delete(e.id) unless e.period
                e.time += e.period
              end
            end
            list
          }

          due.sort_by(&:last).each do |e, time|
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
          batch = []
          Session.with_context(session: @session, time: time, batch: batch) do
            entry.block.call
          end

          if deadline && @transport.position >= deadline
            warn "Skipped the commands scheduled for #{entry.description}: the block finished after its time"
          else
            batch.each(&:call)
          end

        rescue => e
          raise if @raise_errors
          warn "Scheduled block for #{entry.description} raised #{e.class}: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
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
        end
      end
    end
  end
end
