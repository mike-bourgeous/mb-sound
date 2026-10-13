require 'json'
require 'fileutils'
require 'io/console'

module MB
  module Sound
    module Help
      # The listening level for help's "try it" examples, set once per user
      # by a level check (`help.level`): a soft tone plays at REFERENCE_DB
      # (dBFS peak at the output), up/down move it in dB steps until it is
      # comfortable, Enter keeps it.  Every example then plays at the chosen
      # level relative to the reference, since the guard spec keeps every
      # example's loudness near the reference tone's (maintainer, 2026-10-13:
      # "consumer expects near 0 for audibility probably.  Maybe start with
      # a level test at -30 and a 'press up or down until level is good'").
      #
      # The level is saved in the user data directory (Help.data_dir,
      # level.json), next to lesson progress.
      #
      # Example (bin/sound.rb):
      #     help.level          # the level check (keys: up/down 3 dB, left/right 1 dB, Enter, q)
      #     help.level -18      # or set it directly (dBFS at the output)
      #     help.level.db       # the level try examples play at
      module Level
        # The level check tone's peak at the output (dBFS) before any change,
        # and the level examples are written for.
        REFERENCE_DB = -30.0

        # The range the level check allows.  The top, -12 dBFS peak for a
        # soft tone, is about as loud as consumer music (around -14 LUFS);
        # the guard spec keeps example peaks under EXAMPLE_PEAK_DB, so
        # examples stay below full scale at the top.
        RANGE = -60.0..-12.0

        # Example peaks allowed at the output at the reference level (the
        # top of RANGE adds 18 dB).
        EXAMPLE_PEAK_DB = -20.0

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

        # The level examples play at: the saved one, else the reference.
        def db = saved || REFERENCE_DB

        # Saves +db+ (clamped to RANGE); returns the saved value.
        def save(db)
          raise ArgumentError, "The level must be a number of dB (got #{db.inspect})" unless db.is_a?(Numeric)
          db = db.to_f.clamp(RANGE.begin, RANGE.end)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate('db' => db, 'reference_db' => REFERENCE_DB, 'saved' => Time.now.utc.to_s))
          db
        end

        # The linear gain for a try example's players: the saved level over
        # the reference, compensating a master gain moved from the default
        # (examples are measured at the default -10 dB).
        def try_gain(master_gain: Session.current.master_gain, db: self.db)
          master_db = 20 * Math.log10([master_gain.to_f, 1e-6].max)
          default_db = 20 * Math.log10(Session::DEFAULT_MASTER_GAIN)
          10 ** ((db - REFERENCE_DB - (master_db - default_db)) / 20.0)
        end

        # The level check tone at full scale (peak 1): a soft A3 triangle
        # swelling once a second.
        def signal
          220.hz.triangle * (0.75.constant + 1.hz.lfo * 0.25)
        end

        # Plays the level check tone through a Session (realtime or not),
        # its gain set so the output peaks at the given dBFS.
        class SessionPlayer
          def initialize(session = Session.current)
            @session = session
            @gain = nil
          end

          def start(db)
            @gain = GraphNode::Constant.new(gain_for(db), sample_rate: 48000)
            @session.add(Level.signal * @gain, name: PLAYER, on: :now, fade: 0)
          end

          def level=(db)
            @gain.constant = gain_for(db) if @gain
          end

          def stop
            @session.remove(PLAYER, fade: 0)
            @gain = nil
          end

          private

          def gain_for(db) = 10 ** (db / 20.0) / [@session.master_gain, 1e-6].max
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
            if result == :done
              Level.save(@db)
              @out.puts "#{c(:ok, '✓')} examples play at #{fmt(@db)} dBFS (#{fmt(@db - REFERENCE_DB, sign: true)} dB from the reference); #{code('help.level')} to change it"
              @db
            else
              @out.puts c(:dim, "level unchanged (#{fmt(Level.db)} dBFS)")
              nil
            end
          ensure
            @player.stop
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
              wrap('Turn it up or down until it is comfortable, about as loud as you would like to hear examples.  Your system volume stays where it is.', indent: 2),
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
