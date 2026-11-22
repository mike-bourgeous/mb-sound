module MB
  module Sound
    module GraphNode
      class LoopPlayer
        # Stretches a live LoopPlayer needs for a new tempo, made on
        # worker threads instead of the render thread (stretch-live-1):
        # a cached spectral stretch takes 0.3-2.5 s to make, so a bpm
        # change used to stop the render thread that long.  The player
        # submits a Job, keeps playing (its previous stretch, or a
        # quicker interim stretch: LoopPlayer::INTERIMS), and crossfades
        # to the new stretch when the job is done.
        #
        # Two lanes, each one thread: :interim (quick stretches, never
        # stuck behind a slow one) and :full.  The threads start on the
        # first job, wait for more without cost, hand the GVL to the
        # render thread whenever it wants it (UI::Yielding, as the UI's
        # workers do), and hold off major GCs while they work (GCQuiet).
        #
        # Only a realtime Session's render thread submits jobs (.live?):
        # offline renders, process_buffer callers, and #prepare make
        # stretches at once, so renders are the same as before at any
        # buffer size.  .simulate makes renders act as if live, for
        # benches and specs (deterministic: the jobs run at once, and the
        # player takes the result after a given time of its own).
        module Restretch
          # A stretch to make: +sample+.stretch(+ratio+, **+options+), every
          # channel's data copied out (on the worker, not the render thread).
          class Job
            # The stretch ratio and the Sample#stretch options.
            attr_reader :ratio, :options

            # The stretched channels (SFloats) once #done?, else nil.
            attr_reader :channels

            # The exception the stretch raised, or nil.
            attr_reader :error

            # The render thread that asked (the worker yields to it).
            attr_reader :render

            # The player frame from which a simulated job may be taken
            # (.simulate), or nil.
            attr_accessor :ready_frame

            # Seconds the stretch took to make (once #done? or failed).
            attr_reader :seconds

            def initialize(sample, ratio, options, render: nil)
              @sample = sample
              @ratio = ratio
              @options = options
              @render = render
              @channels = nil
              @error = nil
              @state = :queued
              @cancelled = false
              @ready_frame = nil
              @seconds = nil
            end

            # True once the stretch is made.
            def done? = @state == :done

            # True if the stretch raised (see #error).
            def failed? = @state == :failed

            # True once made or failed.
            def finished? = @state == :done || @state == :failed

            # No longer wanted: a job not started yet is skipped.
            def cancel
              @cancelled = true
              nil
            end

            def cancelled? = @cancelled

            # Makes the stretch (the worker, or the caller when simulated).
            def run
              if @cancelled
                @state = :cancelled
                return nil
              end
              @state = :running
              t = MB::U.clock_now
              s = (@ratio - 1).abs < 1e-12 ? @sample : @sample.stretch(@ratio, **@options)
              @channels = Array.new(@sample.channel_count) { |c| s.data(c) }.freeze
              @seconds = MB::U.clock_now - t
              @state = :done
              nil
            rescue StandardError => e
              @seconds = MB::U.clock_now - t if t
              @error = e
              @state = :failed
              nil
            end
          end

          # One worker thread and its queue.
          class Lane
            def initialize(name)
              @name = name
              @queue = Thread::Queue.new
              @thread = nil
              @mutex = Mutex.new
              @done = 0
              @busy = 0.0
            end

            # Queues +job+ (never blocks; starts the thread if needed).
            def submit(job)
              start unless @thread&.alive?
              @queue << job
              job
            end

            # { jobs:, busy_seconds:, waiting: } so far.
            def stats = { jobs: @done, busy_seconds: @busy, waiting: @queue.length }

            # Stops the thread (jobs waiting are dropped).
            def close
              t = @mutex.synchronize { x = @thread; @thread = nil; x }
              @queue.clear
              @queue << :close if t
              t&.join(5)
              nil
            end

            private

            def start
              @mutex.synchronize do
                return if @thread&.alive?
                @thread = Thread.new { run }
                @thread.name = "MB::Sound restretch #{@name}"
                @thread.priority = -3
                @thread.report_on_exception = false
              end
            end

            def run
              Thread.current[:mb_sound_live] = true
              loop do
                job = @queue.pop
                break if job == :close
                next if job.cancelled?
                yielding(job.render) do
                  GCQuiet.during { job.run }
                end
                @done += 1
                @busy += job.seconds.to_f
              end
            end

            # Hands the GVL to +render+ while the block runs, and stops
            # yielding when the queue is empty.
            def yielding(render)
              y = defined?(MB::Sound::UI::Yielding) && render&.alive?
              MB::Sound::UI::Yielding.join(Thread.current, render: render) if y
              yield
            ensure
              MB::Sound::UI::Yielding.leave(Thread.current) if y && @queue.empty?
            end
          end

          @lanes = { interim: Lane.new('interim'), full: Lane.new('full') }
          @simulate = nil
          @closing = nil

          class << self
            # nil (default), or { full: seconds, interim: seconds } to act
            # as if live in any render: jobs are made at once on the
            # calling thread and taken that much of the player's own time
            # after they were asked for (benches and specs; see
            # Restretch).
            attr_reader :simulate

            def simulate=(times)
              raise ArgumentError, 'simulate is nil or { full: seconds, interim: seconds }' unless times.nil? || (times.is_a?(Hash) && (times.keys - %i[full interim]).empty?)
              @simulate = times&.dup&.freeze
            end

            # True on a realtime Session's render thread (stretches go to
            # the workers) or while .simulate is set.
            def background?
              return true if @simulate
              span = Thread.current[:mb_sound_span]
              s = span&.session
              s ? s.realtime? && Thread.current.equal?(s.render_thread) : false
            end

            # Queues +job+ on +lane+ (:interim or :full), or with .simulate
            # makes it at once and sets its #ready_frame +frame+ plus the
            # lane's time at +rate+.  Returns +job+.
            def submit(job, lane, frame: 0, rate: 48000)
              if @simulate
                job.run
                job.ready_frame = frame + (@simulate.fetch(lane, 0) * rate).round
                return job
              end
              @closing ||= ExitClose.register(self)
              @lanes.fetch(lane).submit(job)
            end

            # { interim: { jobs:, busy_seconds:, waiting: }, full: ... }.
            def stats = @lanes.transform_values(&:stats)

            # Stops the worker threads (ExitClose at exit).
            def close
              @lanes.each_value(&:close)
              nil
            end
          end
        end
      end
    end
  end
end
