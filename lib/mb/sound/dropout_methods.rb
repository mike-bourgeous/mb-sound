module MB
  module Sound
    # The console's `dropouts` command (console-offers-1, 2026-11-21): a
    # DropoutProbe on the background Session without typing its class
    # name.  It always saves its log (.json, .csv, .txt) to the handoff
    # inbox, tmp/dropout_probe/ of the main checkout ($MB_SOUND_CHECKOUT_TMP
    # moves it; DropoutProbe.dir), and each action prints one short line
    # (a Status), since Pry would print a probe's records otherwise.
    # `MB_SOUND_DROPOUT_PROBE=1 bin/sound.rb` starts one with the console
    # (#start_dropouts_from_env), so a whole session is probed.
    module DropoutMethods
      # What #dropouts takes.
      DROPOUT_ACTIONS = %i[start report stop].freeze

      # What #dropouts returns: one line in the console.  `dropouts.report`
      # and `dropouts.stop` do what `dropouts :report` and `:stop` do.
      Status = Data.define(:line) do
        def to_s = line
        def inspect = line
        def pretty_print(q) = q.text(line)

        DROPOUT_ACTIONS.each do |name|
          define_method(name) { MB::Sound.dropouts(name) }
        end
      end

      class << self
        # The console's probe (running or finished), or nil.
        attr_accessor :probe

        # The status line of +probe+.
        def status(probe)
          return Status.new('dropouts: no probe has run (dropouts starts one)') unless probe

          d = probe.dropouts.dup
          causes = d.map { |x| x[:result][:cause] }.tally
          top = causes.max_by { |_, n| n }
          likely = top ? ", most likely #{top[0]} (#{top[1]} of #{d.length})" : ''
          if probe.running?
            Status.new("dropouts: probing for #{clock(probe.elapsed)}, #{count(d.length)} so far#{likely} " \
                       "(dropouts :report, :stop; saves to #{probe.paths[:json]})")
          else
            Status.new("dropouts: stopped after #{clock(probe.elapsed)}, #{count(d.length)}#{likely}; saved #{saved(probe)}")
          end
        end

        # "3 dropouts", "1 dropout".
        def count(n) = "#{n} dropout#{'s' unless n == 1}"

        # m:ss.
        def clock(seconds)
          m, s = seconds.to_f.round.divmod(60)
          format('%d:%02d', m, s)
        end

        # The saved files: the .json path, the others beside it.
        def saved(probe)
          p = probe.paths
          "#{p[:json]} (.csv and .txt beside it)"
        end
      end

      # A DropoutProbe on the background Session (DropoutProbe; design
      # note latency_probe.md, Dropout probe): every underrun of the sound
      # card while it runs gets a line with its likely cause (GC, render,
      # the GVL, a lock, the system, YJIT, the device, a queue shrink),
      # and the log is always saved, to tmp/dropout_probe/ in the main
      # checkout (DropoutProbe.dir).  With a screen up the lines print in
      # the REPL pane.
      #
      # +what+: :start (the default; says so if one runs), :report (the
      # report so far, still running), :stop (stops, prints the report and
      # where the files are).  With no argument while a probe runs, its
      # status: time, dropouts so far, the most likely cause so far.
      # Options for :start go to the probe (DropoutProbe#initialize, e.g.
      # +system: false+ for no system probe).  Returns a Status (one line).
      #
      #     dropouts             # start
      #     dropouts             # => dropouts: probing for 2:10, 3 dropouts so far, most likely gc (2 of 3) ...
      #     dropouts :report
      #     dropouts :stop
      def dropouts(what = nil, **opts)
        probe = DropoutMethods.probe
        running = probe&.running?
        return DropoutMethods.status(probe) if what.nil? && running

        what = (what || :start).to_s.delete_prefix(':').to_sym
        unless DROPOUT_ACTIONS.include?(what)
          raise ArgumentError, "dropouts takes #{DROPOUT_ACTIONS.map(&:inspect).join(', ')} (got #{what.inspect}#{UI::Facade.did_you_mean(what, DROPOUT_ACTIONS)})"
        end
        raise ArgumentError, "dropouts #{what.inspect} takes no options (they go with :start)" unless what == :start || opts.empty?

        case what
        when :start
          if running
            s = DropoutMethods.status(probe)
            return Status.new(s.line.sub('dropouts: probing', 'dropouts: already probing'))
          end
          probe = DropoutProbe.start(Session.current, json: DropoutProbe.default_path('console'), name: 'console', announce: false, follow: true, **opts)
          DropoutMethods.probe = probe
          Status.new("dropouts: probing #{probe.describe}; saves to #{probe.paths[:json]} (dropouts :report, :stop)")
        when :report
          return DropoutMethods.status(nil) unless probe
          puts probe.report
          DropoutMethods.status(probe)
        else # :stop
          return Status.new('dropouts: none running (dropouts starts one)') unless running
          probe.stop
          puts probe.report
          DropoutMethods.status(probe)
        end
      end

      # Starts the console's probe when MB_SOUND_DROPOUT_PROBE is set (1,
      # or a .json path) as scripts do (DropoutProbe.from_env), printing its
      # status line; bin/sound.rb calls it once nothing else is starting.
      # Returns the probe or nil.
      def self.start_from_env(env: ENV)
        probe = DropoutProbe.from_env(Session.current, name: 'console', env: env, announce: false, follow: true)
        return nil unless probe

        self.probe = probe
        Internal.console_puts("dropouts: probing #{probe.describe} (MB_SOUND_DROPOUT_PROBE); saves to #{probe.paths[:json]} (dropouts :report, :stop)")
        probe
      end
    end
  end
end
