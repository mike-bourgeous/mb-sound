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
module ForkScript
  # Runs +script+ with +args+ in a forked child, returning the combined
  # stdout/stderr text and the Process::Status.  +env+ is merged into ENV
  # in the child.
  def fork_script(script, *args, env: {})
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      SubprocessCoverage.save_fork_coverage_at_exit

      $stdin.reopen(File::NULL)
      $stdout.reopen(writer)
      $stderr.reopen(writer)
      writer.close
      $stdout.sync = true
      $stderr.sync = true

      ENV.update(env)
      $0 = script
      ARGV.replace(args.map(&:to_s))

      load File.expand_path(script)
    end

    writer.close
    output = reader.read
    reader.close
    Process.wait(pid)

    [output, $?]
  end
end

module SubprocessCoverage
  class << self
    # Called in a forked child: records the coverage counts inherited from
    # the parent and, at exit, saves only what the child added, in the same
    # format as spec/subprocess_coverage_helper.rb.
    def save_fork_coverage_at_exit
      return unless Coverage.running?

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
