# Processes started by library code while a realtime Session renders
# (audio-safety-2, 2026-11-01).  Starting a process from a big Ruby process
# forks with the GVL held (macOS has no vfork path), so the render thread
# can't write while it lasts: a session's first ui.note ran `git rev-parse`
# (19 ms of render-thread GVL wait in the container, more on the Mac's
# heap).  Live paths (console commands, the UI and its panes, saving
# documents) never start processes (CLAUDE.md rules; Internal.git_dirs reads
# git's files instead).
#
# The guard wraps Process.spawn/fork, Kernel#spawn/system/`/fork (Open3
# calls Kernel#spawn), and IO.popen; while a Session's render thread runs,
# a call whose nearest mb-* library frame (lib/mb/... of mb-sound or a
# sibling gem) isn't in ALLOWED is recorded, and the example fails.
# Process starts from spec code (git in a spec, fork_script) don't count.
#
# MB_SOUND_SPAWN_CHECK: "fail" (default), "report" (listed after the run),
# or "off".
module SpawnGuard
  MODES = %w[fail report off].freeze

  # Library files allowed to start a process while a Session plays, with
  # the reason.  Each is a known risk of the same kind, kept until its own
  # fix (terminal_ui.md lists them).
  ALLOWED = {
    'lib/mb/sound/io_base.rb' => 'ffmpeg pipes for file and ffmpeg I/O (recordings, ffmpeg outputs, file inputs) open with IO.popen',
  }.freeze

  @records = []
  @live_names = ['MB::Sound::Session'].freeze

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_SPAWN_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_SPAWN_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    # True while a Session's render thread runs.
    def live?
      Thread.list.any? { |t| t.alive? && @live_names.include?(t.name) }
    end

    # Records a process start (+kind+, +args+) from library code while a
    # Session plays.
    def check(kind, args)
      return if @checking || mode == 'off' || !live?
      @checking = true
      site = caller_locations(2).find { |l|
        path = (l.absolute_path || l.path).to_s
        path.include?('/lib/mb/') && !path.end_with?('spec/support/spawn_guard.rb')
      }
      return unless site
      rel = (site.absolute_path || site.path).sub(%r{\A.*?/(lib/mb/)}, '\1')
      return if ALLOWED.key?(rel)
      cmd = args.flatten.reject { |a| a.is_a?(Hash) }.first(4).map(&:to_s).join(' ')
      (@pending ||= []) << "#{kind} `#{cmd}` from #{rel}:#{site.lineno} (#{site.label})"
    ensure
      @checking = false
    end

    # What was recorded since the last call.
    def take
      list = @pending || []
      @pending = []
      list
    end
  end

  module ProcessHooks
    def spawn(*args, **opts)
      SpawnGuard.check(:spawn, args)
      super
    end

    def fork(...)
      SpawnGuard.check(:fork, [])
      super
    end
  end

  module KernelHooks
    private

    def spawn(*args, **opts)
      SpawnGuard.check(:spawn, args)
      super
    end

    def system(*args, **opts)
      SpawnGuard.check(:system, args)
      super
    end

    def `(cmd)
      SpawnGuard.check(:backtick, [cmd])
      super
    end

    def fork(...)
      SpawnGuard.check(:fork, [])
      super
    end
  end

  module IOHooks
    def popen(*args, **opts, &block)
      SpawnGuard.check(:popen, args)
      super
    end
  end
end

unless SpawnGuard.mode == 'off'
  Process.singleton_class.prepend(SpawnGuard::ProcessHooks)
  Kernel.prepend(SpawnGuard::KernelHooks)
  Kernel.singleton_class.prepend(SpawnGuard::ProcessHooks) # (Kernel.spawn, Kernel.fork)
  IO.singleton_class.prepend(SpawnGuard::IOHooks)

  RSpec.configure do |config|
    config.before(:each) { SpawnGuard.take }

    config.after(:each) do |example|
      list = SpawnGuard.take
      next if list.empty?
      if SpawnGuard.mode == 'fail'
        raise "library code started a process while a Session played (a fork holds the GVL: a dropout): #{list.uniq.join('; ')} " \
              '(read files instead, or see spec/support/spawn_guard.rb)'
      end
      SpawnGuard.records << { 'example' => example.location, 'spawns' => list.uniq }
    end

    config.after(:suite) do
      list = SpawnGuard.records
      unless list.empty?
        puts "\nProcesses started by library code while a Session played (#{list.length} examples; MB_SOUND_SPAWN_CHECK=fail fails them):"
        list.first(40).each { |r| puts "  #{r['example']}  #{r['spawns'].join('; ')}" }
      end
    end
  end
end
