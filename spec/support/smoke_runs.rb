require 'etc'
require 'fileutils'
require 'open3'

# Runs the bin/ script smoke renders (spec/bin/script_smoke_spec.rb) as
# real processes a few at a time instead of one after another: they were
# about 125 s of the smoke run's ~170, each a new Ruby process using one
# core (test-speed-2).  Each run is still its own process with its own
# output, status, and files, checked by its own example.
#
# A spec file declares its runs (#add, with the example tag smoke_run:
# KEY), starts the ones its selected examples need in a before(:context)
# (#start), and each example takes its run's [output, status] (#take),
# waiting for it if needed (a run nothing started runs then).  Warnings a
# run prints go to a directory of its own and move to WarningGuard.dir when
# its example takes it, so they fail that example, as for a run started
# inside it.
#
# MB_SOUND_SMOKE_JOBS sets how many run at once (default half the cores,
# at most 8; 1 runs them one at a time).
class SmokeRuns
  Run = Struct.new(:key, :command, :env, :warnings_dir, :output, :status, :started, :done, keyword_init: true)

  def self.default_jobs
    Integer(ENV['MB_SOUND_SMOKE_JOBS'] || [[Etc.nprocessors / 2, 1].max, 8].min)
  end

  # +dir+ is where runs keep their warnings directories (one each).
  def initialize(dir, jobs: SmokeRuns.default_jobs)
    @dir = dir
    @jobs = jobs
    @runs = {}
    @mutex = Mutex.new
    @cond = ConditionVariable.new
    @threads = []
  end

  # Declares run +key+: a shell +command+ (stdout and stderr together, like
  # `command 2>&1`) with +env+ added.
  def add(key, command, env: {})
    raise ArgumentError, "smoke run #{key.inspect} added twice" if @runs.key?(key)

    @runs[key] = Run.new(key: key, command: command, env: env, warnings_dir: File.join(@dir, "run-#{@runs.length}"), started: false, done: false)
  end

  # The keys of the runs that the examples RSpec selected will take (their
  # smoke_run: metadata).
  def self.selected_keys
    RSpec.world.filtered_examples.values.flatten.filter_map { |e| e.metadata[:smoke_run] }
  end

  # Starts the runs for +keys+ (in that order) on up to +jobs+ threads.
  def start(keys)
    queue = Queue.new
    keys.each { |k| queue << @runs.fetch(k) }
    queue.close
    @threads = Array.new([@jobs, keys.length].min) {
      Thread.new do
        Thread.current.report_on_exception = false
        while (run = queue.pop)
          execute(run)
        end
      end
    }
  end

  # Waits for run +key+ (running it now if nothing started it) and returns
  # [output, Process::Status], with its warnings handed to WarningGuard.
  def take(key)
    run = @runs.fetch(key)
    execute(run)
    @mutex.synchronize { @cond.wait(@mutex) until run.done }
    move_warnings(run)
    [run.output, run.status]
  end

  # Stops waiting for runs no example took (their threads finish them).
  def stop
    @threads.each(&:join)
  end

  private

  # Runs +run+ unless it started already.
  def execute(run)
    @mutex.synchronize {
      return if run.started

      run.started = true
    }
    FileUtils.mkdir_p(run.warnings_dir)
    output, status = Open3.capture2e(run.env.merge('MB_SOUND_WARNINGS_DIR' => run.warnings_dir), run.command, stdin_data: '')
    @mutex.synchronize {
      run.output = output
      run.status = status
      run.done = true
      @cond.broadcast
    }
  end

  def move_warnings(run)
    return unless WarningGuard.dir && File.directory?(run.warnings_dir)

    Dir[File.join(run.warnings_dir, '*.warnings')].each { |f| FileUtils.mv(f, WarningGuard.dir) }
  end
end
