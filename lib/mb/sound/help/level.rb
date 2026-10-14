require 'json'
require 'fileutils'
require 'io/console'

module MB
  module Sound
    module Help
      # The listening level, set once per user by a level check
      # (`help.level`; bin/sound.rb runs it before the first prompt): a soft
      # tone plays at REFERENCE_DB (dBFS peak at the output), up/down move
      # it in dB steps until it is comfortable, Enter keeps it (maintainer,
      # 2026-10-13: "consumer expects near 0 for audibility probably.  Maybe
      # start with a level test at -30 and a 'press up or down until level
      # is good'").
      #
      # The level becomes the monitor trim (Session::MonitorTrim, the
      # console's #monitor_gain): the chosen level over the reference, for
      # live playback only (examples, lessons, and everything typed), after
      # the master chain; renders, recordings, and takes never hear it.
      # Examples are written to play near the reference tone's loudness, so
      # they play near the chosen level.  Saved in the user data directory
      # (Help.data_dir, level.json) next to lesson progress.
      #
      # Example (bin/sound.rb):
      #     help.level          # the level check (keys: up/down 3 dB, left/right 1 dB, Enter, q)
      #     help.level -18.db   # or set it directly (the tone's peak at the output)
      #     monitor_gain.to_db  # the trim it set (+12 here)
      module Level
        # The level check tone's peak at the output (dBFS) with no trim, and
        # the level examples are written for.
        REFERENCE_DB = -30.0

        # The range the level check allows: up to -3 dBFS peak for the tone
        # (about -9 dBFS RMS; maintainer, 2026-10-13: "Ok to peak to -3 if
        # the user chooses it").
        RANGE = -60.0..-3.0

        # How far an example may peak over the level check tone (the guard
        # spec checks it at the reference).  At a chosen level L, examples
        # peak at most at L + 9 dB, so they stay under full scale up to a
        # tone level of -9 dBFS; above that, transient peaks can reach the
        # monitor trim's clip (which warns; see Session::MonitorTrim).
        EXAMPLE_PEAK_OVER_TONE_DB = 9.0

        # Example loudness allowed around the reference tone's (LU).
        EXAMPLE_LOUDNESS_WINDOW = 7.0

        # Key steps (dB).
        STEP_DB = 3.0
        FINE_DB = 1.0

        # The player name the level check plays under.
        PLAYER = :help_level

        module_function

        def path = File.join(Help.data_dir, 'level.json')

        # The saved level (dBFS at the output), or nil before the first
        # level check.
        def saved
          db = JSON.parse(File.read(path))['db']
          db.is_a?(Numeric) ? db.to_f.clamp(RANGE.begin, RANGE.end) : nil
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        def saved? = !saved.nil?

        # The listening level: the saved one, else the reference.
        def db = saved || REFERENCE_DB

        # The monitor trim (linear) for a listening level of +db+.
        def trim_for(db) = 10 ** ((db - REFERENCE_DB) / 20.0)

        # Saves +db+ (clamped to RANGE) and sets the monitor trim from it;
        # returns the saved value.
        def save(db)
          raise ArgumentError, "The level must be a number of dB (got #{db.inspect})" unless db.is_a?(Numeric)
          db = db.to_f.clamp(RANGE.begin, RANGE.end)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate('db' => db, 'reference_db' => REFERENCE_DB, 'saved' => Time.now.utc.to_s))
          apply
          db
        end

        # Sets the monitor trim from the saved level (bin/sound.rb at
        # startup); leaves it alone if there is none.  Returns the trim.
        def apply
          Session.monitor_gain = trim_for(saved) if saved?
          Session.monitor_gain
        end

        # The level check tone at full scale (peak 1): a soft A3 triangle
        # swelling once a second.
        def signal
          220.hz.triangle * (0.75.constant + 1.hz.lfo * 0.25)
        end

        # Plays the level check tone through a Session at the reference peak
        # (before the trim) and moves the monitor trim, so the output peaks
        # at the asked dBFS in a Session that applies the trim (a realtime
        # one, or +monitor: true+).  #stop restores the trim it found.
        class SessionPlayer
          def initialize(session = Session.current)
            @session = session
          end

          def start(db)
            @old_trim = Session.monitor_gain
            gain = 10 ** (REFERENCE_DB / 20.0) / [@session.master_gain, 1e-6].max
            @session.add(Level.signal * gain, name: PLAYER, on: :now, fade: 0)
            self.level = db
          end

          def level=(db)
            Session.monitor_gain = Level.trim_for(db)
          end

          def stop
            @session.remove(PLAYER, fade: 0)
            Session.monitor_gain = @old_trim if @old_trim
            @old_trim = nil
          end
        end

        # The level check's key loop, with injectable +input+ (anything
        # with #getch or #getc), +out+, and +player+ (#start(db), #level=,
        # #stop), so specs run it without a terminal or a sound card.
        class Calibration
          include Text

          KEYS = {
            "\e[A" => STEP_DB, '+' => STEP_DB, '=' => STEP_DB, 'k' => STEP_DB,
            "\e[B" => -STEP_DB, '-' => -STEP_DB, '_' => -STEP_DB, 'j' => -STEP_DB,
            "\e[C" => FINE_DB, 'l' => FINE_DB,
            "\e[D" => -FINE_DB, 'h' => -FINE_DB,
          }.freeze

          DONE = ["\r", "\n", ' ', 'y'].freeze
          CANCEL = ['q', "\e", "\x03", "\x04", nil].freeze

          attr_reader :db

          def initialize(input: $stdin, out: $stdout, player: SessionPlayer.new, start_db: Level.db)
            @input = input
            @out = out
            @player = player
            @db = start_db.to_f.clamp(RANGE.begin, RANGE.end)
          end

          # Runs the key loop; saves and returns the chosen level, or
          # returns nil if cancelled (the saved level stays).
          def run
            @stopped = false
            @out.puts intro
            @player.start(@db)
            show
            result = loop do
              case (r = key(read_key))
              when :done, :cancel then break r
              end
              show
            end
            @out.print "\r\e[K"
            @player.stop
            @stopped = true
            if result == :done
              Level.save(@db)
              @out.puts "#{c(:ok, '✓')} level #{fmt(@db)} dBFS: monitor trim #{fmt(@db - REFERENCE_DB, sign: true)} dB for live playback (renders unchanged); #{code('help.level')} to change it"
              @db
            else
              @out.puts c(:dim, "level unchanged (#{fmt(Level.db)} dBFS)")
              nil
            end
          ensure
            @player.stop unless @stopped
          end

          # Applies one key: returns :done, :cancel, or nil (level moved or
          # key ignored).
          def key(k)
            return :done if DONE.include?(k)
            return :cancel if CANCEL.include?(k)
            if k == 'r'
              move_to(REFERENCE_DB)
            elsif (step = KEYS[k])
              move_to(@db + step)
            end
            nil
          end

          # The status line (without the carriage return).
          def status
            pos = (@db - RANGE.begin) / (RANGE.end - RANGE.begin)
            n = 24
            full = (pos * n).round
            "#{c(:key, format('%6s dBFS', fmt(@db)))} #{c(:bar, '▕' + '█' * full + '·' * (n - full) + '▏')} " \
              "#{c(:dim, '↑↓ 3 dB  ←→ 1 dB  r reset  Enter keep  q cancel')}"
          end

          private

          def intro
            [
              "#{c(:title, 'level check')} #{c(:dim, "a soft tone at #{fmt(@db)} dBFS")}",
              wrap('Turn it up or down until it is comfortable, about as loud as you would like to hear mb-sound; Enter keeps it.  This sets a monitor trim for live playback only (renders and recordings are unchanged); your system volume stays where it is.', indent: 2),
            ].join("\n")
          end

          def move_to(db)
            @db = db.clamp(RANGE.begin, RANGE.end)
            @player.level = @db
          end

          def show
            @out.print "\r\e[K#{status}"
            @out.flush if @out.respond_to?(:flush)
          end

          # One key, with arrow keys' escape sequences read whole.
          def read_key
            k = getch
            return k unless k == "\e"
            # An arrow key sends ESC [ A at once; ESC alone has nothing after
            return k unless ready?
            k + getch.to_s + getch.to_s
          end

          def getch
            if @input.respond_to?(:raw) && @input.respond_to?(:getch) && @input.tty?
              @input.getch
            elsif @input.respond_to?(:getc)
              @input.getc
            else
              @input.getch
            end
          end

          def ready?
            return !@input.eof? if @input.is_a?(StringIO)
            @input.respond_to?(:wait_readable) ? !@input.wait_readable(0.05).nil? : true
          end

          def fmt(v, sign: false)
            s = v.round == v ? v.round.to_s : format('%.1f', v)
            sign && v >= 0 ? "+#{s}" : s
          end
        end
      end
    end
  end
end
