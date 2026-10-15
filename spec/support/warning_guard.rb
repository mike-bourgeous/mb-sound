# Keeps the suite free of Ruby warnings (the maintainer's 0-warnings rule,
# enforced since 2026-10-14): every warning goes through Warning.warn,
# which this module wraps (prepended to Warning's singleton class) to
# record any warning that reaches the real stderr.  spec_helper then fails
# the example that printed it, or the run for warnings printed outside an
# example (while loading files, in before(:all) or after(:suite) hooks).
#
# - Warnings a spec triggers on purpose are expected with
#   `expect { ... }.to output(/text/).to_stderr` (or
#   `to_stderr_from_any_process`): warnings printed while stderr is
#   captured are the matcher's to check, so they aren't recorded.
# - Ruby subprocesses started by specs (bin/ scripts, fork_script children)
#   load this file through RUBYOPT (spec/subprocess_warning_helper.rb) and
#   write what they record to WarningGuard.dir at exit; the example that
#   started them fails with it.  A spec that expects a script's warning
#   checks the script's output and calls `expect_script_warnings(/text/)`.
# - ALLOWED lists the few warnings from code we don't control, each with
#   its reason.
#
# Besides the default categories, :deprecated and :performance warnings
# are on (Ruby leaves both off by default; :experimental is already on).
# :deprecated warnings fail like any other.  :performance warnings (so far
# all "reached 8 shape variations" for classes that set instance variables
# in varying orders; fixed in warnings-2, 2026-10-15, by setting every
# variable in the constructor, see GraphNode::IvarPreset) fail the example
# that triggered them too, but are never printed during the run and are
# recorded even while stderr is captured, since Ruby emits each once per
# process at whichever example happens to trigger it, which would make
# stderr assertions depend on example order.
# MB_SOUND_WARNINGS_PERFORMANCE=report only lists them after the run (as
# before warnings-2).
#
# In the spec process $VERBOSE is true (rspec's config.warnings, set after
# the library loads), so verbose-only warnings (unused variables, method
# redefinitions, ...) count from then on.  Subprocesses keep the $VERBOSE
# a script runs with.
module WarningGuard
  # [pattern, reason] for warnings from code we don't control that are let
  # through: printed only if Ruby would print them without this guard (not
  # in categories Ruby leaves off), and never failing anything.  Keep this
  # short: our own warnings are fixed, or expected by the spec that
  # triggers them.
  ALLOWED = [
    [%r{/gems/pry-[\d.]+/lib/pry/\S+\.rb:\d+: warning: OpenStruct use is discouraged},
     'pry 0.14.2 uses OpenStruct for its config and state (:performance); pinned by the gemspec (~> 0.14.0) and pry-byebug 3.10 (< 0.15)'],
    [%r{/gems/prettyprint-[\d.]+/lib/prettyprint\.rb:\d+: warning: literal string will be frozen},
     'prettyprint 0.2.0 (a pp dependency, locked in Gemfile.lock) appends to a chilled literal (:deprecated); 0.2.1 exists'],
    [%r{/gems/csv-[\d.]+/lib/csv/writer\.rb:\d+: warning: literal string will be frozen},
     'csv 3.3.6 (locked in Gemfile.lock; bin/resample_benchmark.rb writes CSV) appends to a chilled literal (:deprecated)'],
  ].freeze

  # Categories Ruby turns off by default, turned on by #install!.
  EXTRA_CATEGORIES = [:deprecated, :performance].freeze

  # Categories whose warnings are never printed, and recorded even while
  # stderr is captured (see above).
  QUIET = ['performance'].freeze

  # Categories whose warnings are reported after the run instead of failing
  # (see above).
  REPORT_ONLY = (ENV['MB_SOUND_WARNINGS_PERFORMANCE'] == 'report' ? ['performance'] : []).freeze

  # A recorded warning: the message, its category (nil for plain
  # warnings), where it came from (the first stack frame outside Ruby's
  # internals and this file, when the message has no location of its own),
  # the process ($0 for subprocesses), and the example running at the time.
  # +report_only+ records (REPORT_ONLY categories) don't fail anything.
  Record = Struct.new(:message, :category, :origin, :process, :example, :report_only, keyword_init: true) do
    def to_s
      text = message.to_s.chomp.gsub("\n", "\n    ")
      text = "#{origin}: #{text}" if origin && !text.match?(/\A\S+:\d+: /)
      cat = category ? " [#{category}]" : ''
      who = process ? " (in #{process})" : ''
      "#{text}#{cat}#{who}"
    end

    def to_h
      super.transform_keys(&:to_s)
    end
  end

  # Prepended to Warning's singleton class.
  module Hook
    def warn(message, category: nil, **kwargs)
      super if WarningGuard.handle(message, category)
    end
  end

  @mutex = Mutex.new
  @records = []
  @example = nil
  @installed = false

  class << self
    # The current example's location (set by spec_helper), included in
    # each Record.
    attr_accessor :example

    # Wraps Warning.warn and turns on the extra categories.  Safe to call
    # more than once.  +subprocess+ writes this process's records to #dir
    # at exit (see #write_records).
    def install!(subprocess: false)
      unless @installed
        Warning.singleton_class.prepend(Hook)
        @installed = true
      end

      EXTRA_CATEGORIES.each { |c| Warning[c] = true }
      baseline_stderr!
      write_records_at_exit if subprocess
    end

    # Where Ruby subprocesses write the warnings they recorded (one JSON
    # file each), set by spec_helper for every child process.
    def dir
      ENV['MB_SOUND_WARNINGS_DIR']
    end

    # Takes and clears the warnings recorded so far.
    def take
      @mutex.synchronize { @records.slice!(0..) }
    end

    # Takes and removes the warnings Ruby subprocesses wrote to #dir.
    def take_subprocess
      return [] unless dir && File.directory?(dir)

      Dir[File.join(dir, '*.warnings')].sort.flat_map do |f|
        records = Marshal.load(File.binread(f)).map { |h| Record.new(**h.transform_keys(&:to_sym)) }
        File.delete(f)
        records
      rescue TypeError, ArgumentError, Errno::ENOENT
        [] # unreadable or already taken
      end
    end

    # Records +message+ unless it's allowed or stderr is captured (an
    # output matcher's job then).  Returns true if the warning should be
    # printed as usual.
    def handle(message, category)
      category = category&.to_s
      return false if reload_warning?(message)

      if QUIET.include?(category)
        return false if allowed?(message)

        add(message, category, report_only: REPORT_ONLY.include?(category))
        return false
      end

      # Allowed warnings print only where Ruby would have printed them
      return !EXTRA_CATEGORIES.include?(category&.to_sym) if allowed?(message)

      add(message, category) unless stderr_captured?
      true
    rescue Exception # rubocop:disable Lint/RescueException -- never break Warning.warn
      true
    end

    def add(message, category, report_only: false)
      rec = Record.new(
        message: message.to_s,
        category: category,
        origin: origin,
        process: @subprocess_name,
        example: @example,
        report_only: report_only
      )
      @mutex.synchronize { @records << rec }
    end

    # A constant redefinition from reloading a script in a fork (see
    # #forked_child!).
    def reload_warning?(message)
      @reloaded && message.start_with?("#{@reloaded}:") &&
        message.match?(/: warning: (?:already initialized constant|previous definition of) /)
    end

    def allowed?(message)
      ALLOWED.any? { |pattern, _reason| pattern.match?(message.to_s) }
    end

    # True while an output matcher captures stderr: `to_stderr` replaces
    # $stderr; `to_stderr_from_any_process` reopens STDERR on a temporary
    # file (a different file than at #baseline_stderr!).
    def stderr_captured?
      return true unless $stderr.equal?(STDERR)

      st = STDERR.stat
      [st.dev, st.ino] != @stderr_id
    rescue IOError, SystemCallError
      true
    end

    # Remembers which file STDERR is now (see #stderr_captured?).  A forked
    # child calls this again after redirecting its stderr.
    def baseline_stderr!
      st = STDERR.stat
      @stderr_id = [st.dev, st.ino]
    rescue IOError, SystemCallError
      @stderr_id = nil
    end

    # Called in a forked child (fork_script) after it redirects stderr:
    # starts a fresh list and writes it to #dir at exit, like a
    # subprocess.
    #
    # A script the spec process already loaded (to test its patches) is
    # loaded again in the child, redefining its constants; those warnings
    # can't happen in a real process, so they're dropped.
    def forked_child!(name)
      $VERBOSE = false # as in a new process (rspec's config.warnings set it in the parent)
      path = File.expand_path(name.to_s)
      @reloaded = $LOADED_FEATURES.include?(path) ? path : nil
      @mutex = Mutex.new
      @records = []
      @example = nil
      baseline_stderr!
      write_records_at_exit(name)
    end

    # Writes this process's records to #dir at exit (if any).
    def write_records_at_exit(name = $0)
      @subprocess_name = name.to_s
      owner = Process.pid
      at_exit do
        next unless Process.pid == owner

        write_records
      end
    end

    def write_records
      records = take
      return if records.empty? || dir.nil? || !File.directory?(dir)

      # Marshal (core) rather than JSON, so nothing is loaded before the
      # script's own `require 'bundler/setup'`; plain Hashes of Strings.
      path = File.join(dir, "#{Process.pid}-#{rand(1 << 32).to_s(16)}.warnings")
      File.binwrite("#{path}.part", Marshal.dump(records.map(&:to_h)))
      File.rename("#{path}.part", path)
    rescue SystemCallError, IOError
      nil
    end

    private

    # The first caller outside Ruby's internals, Kernel#warn, and this
    # file, as "path:line".
    def origin
      loc = caller_locations(1, 40)&.find { |l|
        path = l.path.to_s
        !path.start_with?('<internal:') && path != __FILE__ && l.label.to_s !~ /\A(?:Kernel#)?warn\z/
      }
      loc && "#{loc.path}:#{loc.lineno}"
    end
  end
end
