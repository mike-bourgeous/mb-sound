module MB
  module Sound
    module Plan
      # Rebuilds off the render thread (render-rebuild-1).  A change to a
      # planned graph (a node left out when its event stream is over, a sum
      # dropping an ended summand, a structural edit) makes the
      # installation rebuild before its next block.  Where that block is a
      # realtime Session's (see Plan.rebuilds), finding the new layout and
      # compiling its programs happen elsewhere instead: the render thread
      # keeps running every region the change didn't touch with its
      # program, runs the touched ones unfused (Installation#held?; the
      # plan is an as-if transformation, so unfused blocks give the same
      # samples), and installs the new layout at the start of a later block
      # (Deferral#apply, Installation#adopt), with the regions whose nodes
      # didn't change kept, programs and all (Installation#find_layout).
      #
      # The build runs on one process-wide thread (Worker), below the
      # render thread's priority, in slices of at most Worker::SLICE
      # seconds holding the Session's render lock: every buffer is rendered
      # with the lock held, and structural edits take it too, so a build
      # never reads a graph a buffer is changing.  Between slices the
      # render thread renders; a structural change meanwhile makes the
      # build start over (#adopt drops it), other changes hold their
      # regions in the new layout and start the next build.
      class Rebuild
        # The live Installation.
        attr_reader :installation

        # The Deferral that installs the result.
        attr_reader :deferral

        # The installation's change count when the build started (see
        # Installation#note_change).
        attr_reader :since

        # The layout found (a dry run Installation holding the regions), or
        # nil.
        attr_reader :layout

        # The exception the build raised, or nil.
        attr_reader :error

        def initialize(installation, deferral)
          @installation = installation
          @deferral = deferral
          @since = installation.changes
          @snapshot = installation.snapshot
          @cancelled = false
          @layout = nil
          @error = nil
          @seconds = nil
        end

        # Stops the build (at its next slice) and makes #adopt ignore it.
        def cancel
          @cancelled = true
        end

        def cancelled?
          @cancelled
        end

        # Thread CPU seconds the build took (after #run).
        attr_reader :seconds

        # Finds the new layout and compiles its new regions (as
        # Installation#precompile does, replanning around nodes that turn
        # out unsupported), calling +slicer+ (if any) between steps.
        def run(slicer = nil)
          started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
          inst = @installation
          shadow = Installation.new(inst.roots, engine: inst.engine, check: inst.check, dry_run: true, unread: inst.unread)
          shadow.shadow_of(inst, @snapshot, slicer)
          current = @snapshot[:regions]
          shadow.find_layout(current)
          10.times do
            shadow.regions.each do |r|
              return if @cancelled
              next if r.program

              # (and what LaneGroups#refresh asks of it, so the thread
              # that renders doesn't compute it)
              prog = r.compile(start: false)
              if prog
                slicer&.call
                prog.signature if inst.engine == :c
                prog.scale_core
              end
              slicer&.call
            end
            break unless shadow.stale_here?

            shadow.find_layout(current)
          end
          @layout = shadow unless @cancelled
        rescue StandardError => e
          @error = e
          @layout = nil
        ensure
          @seconds = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - started if started
        end
      end

      # Where a thread that renders (a realtime Session's render thread)
      # wants rebuilds done (see Rebuild): Plan.deferral while it renders a
      # span.  +lock+ is held while the thread renders (the Session's render
      # lock); builds run on the Worker thread in slices holding it (+mode+
      # :thread), or with +mode+ :next_span at the start of the next span
      # (a deterministic stand-in for specs: the same holds and swaps, the
      # build itself on the rendering thread).
      class Deferral
        attr_reader :lock, :mode

        def initialize(lock, mode: :thread)
          raise ArgumentError, "Unknown deferral mode #{mode.inspect}" unless [:thread, :next_span].include?(mode)

          @lock = lock
          @mode = mode
          @ready = Thread::Queue.new
          @next_span = []
          @closed = false
          @mutex = Mutex.new
          @building = 0
          @adopted = 0
          @dropped = 0
          @seconds = 0.0
        end

        # Rebuilds installed, and dropped (a structural change during the
        # build, or an error; see Installation#adopt).
        attr_reader :adopted, :dropped

        # Thread CPU seconds the builds took.
        attr_reader :seconds

        # Starts +job+ (a Rebuild; called by Installation#stale?).
        def submit(job)
          @mutex.synchronize { @building += 1 } unless @mode == :next_span
          if @mode == :next_span
            @next_span << job
          else
            Worker.submit(job)
          end
        end

        # Called by the Worker when +job+ is done.
        def deliver(job)
          @ready << job
          @mutex.synchronize { @building -= 1 }
        end

        # True if no build is running on the worker thread (finished ones
        # land at the next span; see #apply).
        def idle?
          @mutex.synchronize { @building == 0 }
        end

        # Installs every finished build (called at the start of a span, on
        # the thread that renders, with the lock held).
        def apply
          unless @next_span.empty?
            list = @next_span
            @next_span = []
            list.each do |job|
              job.run unless job.cancelled?
              @ready << job
            end
          end
          return if @ready.empty?

          until @ready.empty?
            job = @ready.pop
            next if job.cancelled?

            @seconds += job.seconds if job.seconds
            if job.installation.adopt(job)
              @adopted += 1
            else
              @dropped += 1
            end
          end
        end

        # Stops installing builds (the Session closed).
        def close
          @closed = true
          @next_span.each(&:cancel)
          @next_span.clear
        end

        def closed?
          @closed
        end
      end

      # The thread that runs Rebuilds for Deferrals in +:thread+ mode.
      module Worker
        # The longest slice of a build (seconds) while holding a
        # Deferral's lock.
        SLICE = 0.0005

        # The thread's Ruby priority: below the render thread (3) and the
        # Session scheduler (-3; see Session::Scheduler::THREAD_PRIORITY).
        THREAD_PRIORITY = -3

        @queue = Thread::Queue.new
        @thread = nil
        @start = Mutex.new

        class << self
          # Queues +job+ (a Rebuild).
          def submit(job)
            @start.synchronize { start unless @thread&.alive? }
            @queue << job
          end

          # The worker thread (nil before the first build).
          attr_reader :thread

          private

          def start
            @thread = Thread.new do
              loop do
                job = @queue.pop
                run(job)
              end
            end
            @thread.name = 'MB::Sound::Plan rebuilds'
            @thread.priority = THREAD_PRIORITY
            @thread.report_on_exception = true
          end

          # Runs +job+ in slices holding its Deferral's lock (see Rebuild).
          def run(job)
            d = job.deferral
            return if job.cancelled? || d.closed?

            lock = d.lock
            deadline = nil
            slicer = lambda do
              raise Cancelled if job.cancelled? || d.closed?
              next if MB::U.clock_now < deadline

              lock.exit
              Thread.pass
              lock.enter
              deadline = MB::U.clock_now + SLICE
            end
            lock.synchronize do
              deadline = MB::U.clock_now + SLICE
              # (builds allocate in bursts: no major GC stopping the render
              # thread meanwhile; see GCQuiet)
              GCQuiet.during { job.run(slicer) }
            end
          rescue StandardError => e
            warn "Plan rebuild failed on the worker thread: #{e.class}: #{e.message}" unless e.is_a?(Cancelled)
          ensure
            d&.deliver(job)
          end
        end

        # Raised inside a build when it is cancelled (see Rebuild#cancel).
        class Cancelled < StandardError; end
      end
    end
  end
end
