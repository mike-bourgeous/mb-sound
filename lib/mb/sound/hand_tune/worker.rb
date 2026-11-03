require 'json'
require 'rbconfig'

module MB
  module Sound
    module HandTune
      # A Ruby process that runs refine jobs (hand-tune-2), so an optimizer
      # pass doesn't compete with the live render thread for the GVL: the
      # console only reads its progress lines (blocking reads, off the
      # GVL).  Started on demand (the console's first tune, Worker.prepare,
      # or refine, Worker.start) through the process starter (Starter:
      # starting a process from the console's big heap forks with the GVL
      # held, audio-safety-2), or directly while nothing plays where no
      # starter runs, it loads mb-sound once (about 2 s, 100 MB) and waits.
      # It runs at a lower CPU priority (nice 10) than the console.
      #
      # Protocol: JSON lines.  To the worker: {"job": RefineJob data},
      # {"stop": true} (ends the job, keeping its best), {"quit": true}.
      # From it: {"ready": true} once loaded, {"progress": [evals, best,
      # start, seconds]} (at most ten a second), {"result": RefineResult
      # data} or {"error": "message"}.
      class Worker
        # Seconds between progress lines.
        PROGRESS_EVERY = 0.1

        class << self
          # The worker the console's refines use (started by .start; nil
          # until then, or after it exited).
          def current
            @current = nil if @current && !@current.alive?
            @current
          end

          # Starts the console's worker unless it runs.  Through the
          # process starter when one runs (bin/sound.rb), at any time;
          # without one, it refuses (an ArgumentError) while a Session
          # renders, unless +force+.  Returns the Worker.
          def start(force: false)
            return current if current
            if !force && Starter.current.nil? && Worker.live_render?
              raise ArgumentError, 'refine: its worker process starts only while nothing plays when no process starter runs ' \
                                   '(starting a process here holds the GVL; bin/sound.rb runs one): stop, then refine again, ' \
                                   'or run it in-process with mode: :here'
            end
            @current = new
          end

          # Starts the console's worker ahead of a refine (the console's
          # tune), so the first refine doesn't wait for it to load, when
          # that's safe: through the process starter, or while nothing
          # plays.  Not when $MB_SOUND_REFINE_WORKER is 0 (the specs).
          # Returns the Worker, or nil.
          def prepare
            return nil if ENV['MB_SOUND_REFINE_WORKER'] == '0'
            return current if current
            return nil if Starter.current.nil? && Worker.live_render?
            start
          rescue StandardError => e
            warn "The refine worker didn't start (#{e.message}); refine will start it"
            nil
          end

          # True while a Session's render thread runs (starting a process
          # then would hold the GVL through the fork).
          def live_render? = Thread.list.any? { |t| t.alive? && t.name == 'MB::Sound::Session' }

          # The worker process's loop (see the protocol above): reads jobs
          # from +input+, writes lines to +output+.
          def serve(input = $stdin, output = $stdout)
            Process.setpriority(Process::PRIO_PROCESS, 0, 10) rescue nil
            output.sync = true
            out = Mutex.new
            say = ->(h) { out.synchronize { output.puts(JSON.generate(h)) } }
            say.(ready: true)
            stop = false
            job = nil
            runner = nil
            while (line = input.gets)
              msg = JSON.parse(line)
              if msg['quit']
                stop = true
                break
              elsif msg['stop']
                stop = true
              elsif msg['job']
                runner&.join
                stop = false
                job = RefineJob.from_json_data(msg['job'])
                runner = Thread.new(job) do |j|
                  last = 0.0
                  r = HandTune.refine_run(j, stop: -> { stop }, progress: ->(e, b, s, t) {
                    next if t - last < PROGRESS_EVERY
                    last = t
                    say.(progress: [e, b, s, t])
                  })
                  say.(result: r.to_json_data)
                rescue StandardError => e
                  say.(error: "#{e.class}: #{e.message.lines.first&.strip}")
                end
              end
            end
            runner&.join
          end
        end

        attr_reader :pid

        def initialize
          lib = File.expand_path('../../..', __dir__)
          gemfile = File.expand_path('../../../../Gemfile', __dir__)
          code = "require 'bundler/setup'; require 'mb-sound'; MB::Sound::HandTune::Worker.serve"
          env = { 'BUNDLE_GEMFILE' => gemfile, 'MB_SOUND_YJIT' => '1', 'RUBYOPT' => ENV['RUBYOPT'].to_s }
          r_in, w_in = IO.pipe
          r_out, w_out = IO.pipe
          begin
            @child = Starter.spawn(env, RbConfig.ruby, '-I', lib, '-e', code, in: r_in, out: w_out)
          ensure
            r_in.close
            w_out.close
          end
          @pid = @child.pid
          @in = w_in
          @out = r_out
          @in.sync = true
          @ready = false
          @lines = Queue.new
          @reader = Thread.new { read_lines }
          @reader.name = 'MB::Sound::HandTune::Worker'
          ExitClose.register(self)
        end

        # True while the process runs.
        def alive?
          @pid && @child.alive? ? true : false
        end

        # Waits up to +timeout+ seconds for the worker to have loaded
        # mb-sound.  Returns true when ready.
        def wait_ready(timeout = 60)
          deadline = MB::U.clock_now + timeout
          until @ready
            return false if MB::U.clock_now > deadline || !alive?
            msg = next_message(0.1)
            @ready = true if msg && msg['ready']
            @early << msg if msg && !msg['ready'] && (@early ||= [])
          end
          true
        end

        # Sends +job+ (a RefineJob).
        def submit(job)
          send_line(job: job.to_json_data)
        end

        # Asks the running job to stop (it sends its best so far).
        def stop
          send_line(stop: true)
        end

        # The next message from the worker (a Hash), waiting up to
        # +timeout+ seconds (nil: none yet).
        def next_message(timeout = nil)
          return @early.shift if @early && !@early.empty?
          @lines.pop(timeout: timeout)
        end

        # Ends the process.
        def close
          send_line(quit: true) rescue nil
          @in&.close rescue nil
          if @pid && !@child.wait(0.2)
            @child.kill(:TERM)
            @child.wait(5)
          end
          @pid = nil
          ExitClose.unregister(self)
        end

        private

        def send_line(h)
          @in.puts(JSON.generate(h))
        end

        def read_lines
          while (line = @out.gets)
            @lines << (JSON.parse(line) rescue { 'error' => "worker said: #{line.strip[0, 200]}" })
          end
        ensure
          @lines << { 'error' => 'the refine worker exited' }
        end
      end
    end
  end
end
