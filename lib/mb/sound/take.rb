require 'fileutils'
require 'rbconfig'

module MB
  module Sound
    # The take: an always-on log of a live performance in the console
    # (bin/sound.rb): every line typed, when it was typed, and exactly when
    # each change it made landed (see Session::Journal).  `take.save` writes
    # it as a Ruby script that replays the performance bit for bit, at any
    # buffer size (see Take::Replay).
    #
    # Console lines reach the take through Pry's :before_eval and
    # :after_eval hooks (see #begin_line and #end_line; bin/sound.rb sets
    # them up).  Lines are evaluated again at their recorded times when the
    # take replays, with every change forced to land where it landed live,
    # so replays are exact as long as the code is deterministic: MB::Sound's
    # random seeds are (the take restores the root generator), but `rand`,
    # `Time.now`, files edited between takes, and live MIDI input are not.
    #
    # Example (bin/sound.rb):
    #     take                 # what has been played so far
    #     take.save            # writes a replay script and prints its path
    #     take.save 'sets/night_bus.rb'
    #     take.restart         # starts a new take
    class Take
      # A console line: its +id+, the Ruby +code+, the Stamp where it was
      # +issued+, and the timeline positions (+lands+) where each change it
      # made landed, in the order they were made.
      Line = Struct.new(:id, :code, :issued, :lands, :skipped, keyword_init: true)

      # Commands that play in the foreground or show things (they would
      # block or draw during a replay), skipped by replays: lines that start
      # with one of these words are kept in the script as comments.
      FOREGROUND = %w[play plot vis visualize wait spy take changes players stopped scheduled scenes tracks help ls].freeze

      class << self
        # The console's take, created when first needed.
        def current
          @current ||= new
        end

        # Replaces the console's take with a fresh one.
        def restart
          @current = new
        end

        # A fresh binding like the console's (Pry's binding in MB::Sound:
        # self and constants are MB::Sound's), with no local variables yet.
        def console_binding
          MB::Sound.module_eval('binding')
        end

        # The id of the console line being evaluated on this thread, or nil.
        def current_line_id
          Thread.current[:mb_sound_take_line]&.last&.id
        end

        # Records where a change landed in the console line being evaluated
        # on this thread (see Session::Changes#change).
        def note_change(session, change)
          take, line = Thread.current[:mb_sound_take_line]
          return unless line && take.session_ok?(session)
          line.lands << (change.lands&.pos || change.time)
        end
      end

      # The lines recorded so far (see Line).
      attr_reader :lines

      # The state when the take started: tempo, bar length, master gain,
      # default fades, sample rate, the root random generator, and when.
      attr_reader :start

      # A directory for saved takes that overrides the default (see #save);
      # a standalone set (e.g. a song script) sets it to keep its takes with
      # it.
      attr_accessor :home

      def initialize(session: nil)
        @session = session
        @lines = []
        @next_id = 0
        @mutex = Mutex.new
        @start = start_state
      end

      # The session whose changes this take records: the one given to
      # .new, or the background session (MB::Sound.bg's).
      def session
        @session || Session.default
      end

      # True if changes made to +session+ belong in this take.
      def session_ok?(session)
        session.equal?(self.session)
      end

      # Starts recording a console line (Pry's :before_eval hook).  Returns
      # the Line.
      def begin_line(code)
        line = @mutex.synchronize {
          @next_id += 1
          Line.new(id: @next_id, code: code.to_s, issued: session.clock, lands: [], skipped: foreground?(code))
        }
        @mutex.synchronize { @lines << line }
        Thread.current[:mb_sound_take_line] = [self, line]
        line
      end

      # Stops recording the current line (Pry's :after_eval hook).
      def end_line
        Thread.current[:mb_sound_take_line] = nil
      end

      # Evaluates +code+ in +binding+ as a console line (for scripts and
      # specs that perform without Pry).  Returns the result.
      def line(code, binding)
        begin_line(code)
        binding.eval(code)
      ensure
        end_line
      end

      # The journal entries for the changes this take's lines made.
      def entries
        ids = @mutex.synchronize { @lines.map(&:id) }
        session.journal.changes.select { |e| ids.include?(e.line) }
      end

      # The scene launches in the take, as [Stamp, scene name] pairs.  The
      # form as played (`take.form` returning a Form whose `to_ruby` prints
      # a `flow do ... end` block) arrives with song forms.
      def form
        warn 'take.form: song forms (flow do ... end) arrive in a later phase; here are the scene launches'
        session.journal.changes.select { |e| e.kind == :scene && e.status == :landed }.map { |e| [e.lands, e.subject] }
      end

      def to_s
        n = @mutex.synchronize { @lines.length }
        "take: #{n} line#{n == 1 ? '' : 's'}, #{entries.length} changes since #{@start[:time]}"
      end

      def inspect
        lines = @mutex.synchronize { @lines.last(12) }
        body = lines.map { |l|
          lands = l.lands.map { |t| session.stamp(t).to_s }.uniq
          "  #{l.issued}#{lands.empty? ? '' : " -> #{lands.join(', ')}"}  #{l.code.lines.first.to_s.strip[0, 70]}"
        }
        ["#<#{self}", *body].join("\n") + '>'
      end

      def pretty_print(q)
        q.text(inspect)
      end

      # The replay script (see #save).
      def to_ruby(title: nil)
        lines = @mutex.synchronize { @lines.dup }
        title ||= "take started #{@start[:time]}"

        out = +"#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby\n"
        out << "# Replay of a live mb-sound #{title}: #{lines.length} console lines.\n"
        out << "# Each line runs again at the time it was typed, with every change it\n"
        out << "# made landing exactly where it landed live.\n"
        out << "#\n"
        out << "#     ruby #{'this_file.rb'} -o take.flac     # renders it\n"
        out << "#     ruby #{'this_file.rb'}                  # plays it\n"
        out << "#     ruby #{'this_file.rb'} -o t.flac -b 367,368   # alternating buffer sizes\n"
        out << "ENV['BUNDLE_GEMFILE'] ||= #{File.expand_path('../../../Gemfile', __dir__).inspect}\n"
        out << "require 'bundler/setup'\n"
        out << "require 'mb-sound'\n\n"
        out << "MB::Sound::Take::Replay.new(\n"
        @start.each do |k, v|
          next if k == :time
          out << "  #{k}: #{ruby_value(v)},\n"
        end
        out << "  ends: #{ruby_value(session.transport.position)},\n"
        out << ") do |r|\n"
        lines.each do |l|
          if l.skipped
            out << "  # skipped (foreground): #{l.code.lines.first.to_s.strip}\n"
            next
          end
          out << "  r.line #{ruby_value(l.issued.pos)}, #{ruby_value(l.lands)}, <<~'RUBY'\n"
          l.code.each_line { |c| out << "    #{c.chomp}\n" }
          out << "  RUBY\n"
        end
        out << "end.main(ARGV, __FILE__)\n"
        out
      end

      # A Replay of this take (see Replay), as #save would write it.
      def replay
        lines = @mutex.synchronize { @lines.reject(&:skipped) }
        Replay.new(**@start.except(:time), ends: session.transport.position) do |r|
          lines.each { |l| r.line(l.issued.pos, l.lands.dup, l.code) }
        end
      end

      # Saves the replay script and prints where.  With no +path+, saves to
      # #home if set, else to the project's sets/ directory with +repo:
      # true+, else to the user data directory (see .data_dir).  Returns
      # the path.
      def save(path = nil, repo: false)
        path ||= File.join(home || (repo ? File.expand_path('../../../sets', __dir__) : self.class.data_dir), "take_#{Time.now.strftime('%Y%m%d_%H%M%S')}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, to_ruby)
        File.chmod(0o755, path)
        puts "Saved the take to \e[1m#{path}\e[0m"
        path
      end

      # Starts a new take (the console's take, if this is it).  Returns the
      # new take.
      def restart
        equal?(self.class.current) ? self.class.restart : self.class.new(session: @session)
      end

      # The user data directory for takes: $XDG_DATA_HOME/mb-sound/takes
      # (~/.local/share/mb-sound/takes) on Linux, ~/Library/Application
      # Support/mb-sound/takes on macOS.
      def self.data_dir
        if RbConfig::CONFIG['host_os'] =~ /darwin/
          File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'takes')
        else
          File.join(ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME'], 'mb-sound', 'takes')
        end
      end

      private

      def foreground?(code)
        FOREGROUND.include?(code.to_s[/\A\s*([a-z_]+[!?]?)/, 1])
      end

      # The state a replay starts from.
      def start_state
        s = @session || Session.default
        {
          bpm: s.transport.bpm,
          bar_length: s.transport.bar_length,
          master_gain: s.master_gain,
          fade_in: s.fade_in,
          fade_out: s.fade_out,
          rng: [Marshal.dump(MB::Sound.root_rng)].pack('m0'),
          time: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        }
      end

      # Ruby source for a value in the replay script.
      def ruby_value(v)
        case v
        when Rational then v.denominator == 1 ? "#{v.numerator}r" : "#{v.numerator}/#{v.denominator}r"
        when Array then "[#{v.map { |x| ruby_value(x) }.join(', ')}]"
        else v.inspect
        end
      end
    end
  end
end

require_relative 'take/replay'
