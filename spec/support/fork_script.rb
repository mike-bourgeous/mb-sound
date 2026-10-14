require 'coverage'

# Runs a bin/ script in a fork of the spec process instead of a new Ruby
# process, skipping the ~0.7 s of Ruby, Bundler, and library startup that
# each script run costs.
#
# The child gets the script's $0 and ARGV, with stdout and stderr going to
# one pipe (like `script 2>&1`) and stdin from /dev/null.  Exit statuses,
# exceptions, and the script's own at_exit hooks behave as in a new
# process (SimpleCov and SpecTmp skip their exit tasks in forked children).
# The script's coverage is saved like a subprocess's (see
# SubprocessCoverage).
#
# Differences from a new process: the child starts with the spec process's
# loaded code and global state (e.g. MB::Sound's transport and tempo), and
# only the forking thread exists in the child.  Use backticks for scripts
# where that matters.
#
# A spec that uses fork_script must also run its script at least once as a
# real process doing real work (not just --help), so load-order problems and
# implicit dependencies masked by the spec process's loaded code still show.
module ForkScript
  # Seconds a forked script may run before fork_script stops it and fails
  # (MB_SOUND_FORK_TIMEOUT overrides).  Forked scripts take seconds; a child
  # once hung for hours with every thread in futex_wait (2026-10-14, a
  # fork of a spec process running bin/graph_profile.rb on the flanger,
  # not reproduced since), holding up the whole suite.
  TIMEOUT = Float(ENV['MB_SOUND_FORK_TIMEOUT'] || 300)

  # Raised when a forked script runs past TIMEOUT.
  class TimedOut < StandardError; end

  # Runs +script+ with +args+ in a forked child, returning the combined
  # stdout/stderr text and the Process::Status.  +env+ is merged into ENV
  # in the child.  A child still running after +timeout+ seconds is
  # stopped (SIGQUIT for its Ruby backtraces, then SIGKILL), and
  # ForkScript::TimedOut is raised with its output and what its threads
  # were waiting on.
  def fork_script(script, *args, env: {}, timeout: TIMEOUT)
    reader, writer = IO.pipe
    parent_threads = Thread.list.map { |t| "#{t.name || 'unnamed'} (#{t.status})" }

    pid = fork do
      reader.close
      SubprocessCoverage.save_fork_coverage_at_exit

      $stdin.reopen(File::NULL)
      $stdout.reopen(writer)
      $stderr.reopen(writer)
      writer.close
      $stdout.sync = true
      $stderr.sync = true
      WarningGuard.forked_child!(script) # this child's warnings fail the example too

      ENV.update(env)
      $0 = script
      ARGV.replace(args.map(&:to_s))

      load File.expand_path(script)
    end

    writer.close
    output, timed_out = ForkScript.read_until(reader, timeout)
    if timed_out
      diagnostics = ForkScript.stop_hung_child(pid, reader, output)
      reader.close
      raise TimedOut, "fork_script(#{[script, *args].map(&:to_s).join(' ')}) ran over #{timeout} s and was killed.\n" \
        "Threads in the spec process at fork: #{parent_threads.join(', ')}\n#{diagnostics}\nOutput:\n#{output}"
    end
    reader.close
    Process.wait(pid)

    [output, $?]
  end

  # Reads +io+ to its end or until +seconds+ pass.  Returns the text and
  # whether it timed out.
  def self.read_until(io, seconds)
    output = +''
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return [output, true] if left <= 0
      next unless io.wait_readable(left)

      output << io.read_nonblock(65536)
    rescue IO::WaitReadable
      next
    rescue EOFError
      return [output, false]
    end
  end

  # What a hung child's threads and children wait on (from /proc), then
  # SIGQUIT (MB::U.sigquit_backtrace prints every Ruby thread, if the child
  # can still run Ruby code) and SIGKILL.  Adds what it printed to +output+.
  def self.stop_hung_child(pid, reader, output)
    lines = Dir["/proc/#{pid}/task/*"].map { |t|
      "  thread #{File.basename(t)} #{File.read("#{t}/comm").strip rescue '?'}: #{File.read("#{t}/wchan") rescue '?'}"
    }
    kids = `ps --ppid #{pid} -o pid=,stat=,wchan:20=,args= 2>/dev/null`.lines.map { |l| "  child #{l.strip[0, 160]}" }

    Process.kill(:QUIT, pid) rescue nil
    more, _ = read_until(reader, 2)
    output << more
    Process.kill(:KILL, pid) rescue nil
    Process.wait(pid) rescue nil

    "Hung child #{pid} (Linux wchan per thread; futex_wait_queue = waiting on a lock or the GVL):\n#{(lines + kids).join("\n")}"
  end

  # Runs +script+ with +args+ in a fork (see #fork_script), or as a real
  # process with +real+ (stdout and stderr combined, stdin from /dev/null),
  # returning the output text and the Process::Status.  Lets a spec switch
  # one run to a real process without a second helper.
  def run_script(script, *args, env: {}, real: false)
    return fork_script(script, *args, env: env) unless real

    output = IO.popen(env, [script, *args.map(&:to_s)], err: [:child, :out], in: File::NULL, &:read)
    [output, $?]
  end
end

module SubprocessCoverage
  class << self
    # Called in a forked child: records the coverage counts inherited from
    # the parent and, at exit, saves only what the child added, in the same
    # format as spec/subprocess_coverage_helper.rb.
    def save_fork_coverage_at_exit
      return unless Coverage.running? && const_defined?(:DIR) # SIMPLECOV=1 (see spec_helper)

      before = project_coverage(Coverage.peek_result)
      owner = Process.pid

      at_exit do
        next unless Process.pid == owner

        after = project_coverage(Coverage.peek_result)
        name = File.join(DIR, "fork-#{Process.pid}-#{rand(1 << 32).to_s(16)}.json")
        File.write("#{name}.part", JSON.dump(coverage_delta(before, after)))
        File.rename("#{name}.part", name)
      rescue => e
        warn "Could not save forked script coverage: #{e}"
      end
    end

    private

    def project_coverage(result)
      root = File.expand_path('../..', __dir__) + '/'
      result.select { |path, _| path.start_with?(root) && !path.include?('/vendor/') }
    end

    # Subtracts +before+ counts from +after+ (both from Coverage.peek_result
    # with lines and branches).
    def coverage_delta(before, after)
      after.to_h { |path, cov|
        old = before[path]
        next [path, cov] unless old

        lines = cov[:lines]&.zip(old[:lines] || [])&.map { |a, b| a && a - (b || 0) }
        branches = cov[:branches]&.to_h { |cond, targets|
          old_targets = old.dig(:branches, cond) || {}
          [cond, targets.to_h { |t, n| [t, n - (old_targets[t] || 0)] }]
        }

        [path, { lines: lines, branches: branches }.compact]
      }
    end
  end
end

RSpec.configure do |config|
  config.include ForkScript
end
