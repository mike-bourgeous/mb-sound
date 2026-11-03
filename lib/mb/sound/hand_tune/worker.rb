require 'json'
require 'rbconfig'

module MB
  module Sound
    module HandTune
      # A Ruby process that runs refine jobs (hand-tune-2), so an optimizer
      # pass doesn't compete with the live render thread for the GVL: the
      # console only reads its progress lines (blocking reads, off the
      # GVL).  Started when no Session renders (bin/sound.rb at startup,
      # Worker.start; starting a process from the console's big heap forks
      # with the GVL held: audio-safety-2), it loads mb-sound once and
      # waits.  It runs at a lower CPU priority (nice 10) than the console.
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

          # Starts the console's worker unless it runs.  Refuses (an
          # ArgumentError) while a Session renders, unless +force+.  Returns
          # the Worker.
          def start(force: false)
            return current if current
            if !force && Worker.live_render?
              raise ArgumentError, 'refine: its worker process starts only while nothing plays (starting a process holds the GVL; ' \
                                   'bin/sound.rb starts it before playing: stop, then refine again, or run it in-process with mode: :here)'
            end
            @current = new
          end

          # Starts the console's worker at startup (bin/sound.rb, before
          # anything plays), unless $MB_SOUND_REFINE_WORKER is 0.  It loads
          # mb-sound in its own process (about 2 s, 100 MB) and waits.
          # Returns the Worker, or nil.
          def prestart
            return nil if ENV['MB_SOUND_REFINE_WORKER'] == '0'
            start
          rescue StandardError => e
            warn "The refine worker didn't start (#{e.message}); refine will start it while nothing plays"
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
          @pid = Process.spawn(env, RbConfig.ruby, '-I', lib, '-e', code, in: r_in, out: w_out)
          r_in.close
          w_out.close
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
          return false unless @pid
          Process.waitpid(@pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          false
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
          if @pid
            unless (Process.waitpid(@pid, Process::WNOHANG) rescue true)
              Process.kill(:TERM, @pid) rescue nil
              Process.waitpid(@pid) rescue nil
            end
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
