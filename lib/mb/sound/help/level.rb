require 'json'
require 'fileutils'
require 'io/console'

module MB
  module Sound
    module Help
      # The listening level, set once per user by a level check
      # (`help.level`; bin/sound.rb runs it before the first prompt): a soft
      # tone plays at REFERENCE_DB (dBFS peak at the output), down/up move
      # it in dB steps until it is comfortable, Enter keeps it (maintainer,
      # 2026-10-13: "consumer expects near 0 for audibility probably.  Maybe
      # start with a level test at -30 and a 'press up or down until level
      # is good'").
      #
      # The level is the monitor trim (Session::MonitorTrim, the console's
      # #monitor_gain) in dB, -60 to 0: it only turns down, and a tone too
      # quiet at 0 dB asks for more system or interface volume instead
      # (audio-safety-2, 2026-11-01: a +15 dB trim hard-clipped the
      # maintainer's -10 dBFS sine).  For live playback only (examples,
      # lessons, and everything typed), after the master chain; renders,
      # recordings, and takes never hear it.  Examples are written to play
      # near the tone's loudness, so they play near the chosen level, and
      # never past full scale from the trim.  Saved in the user data
      # directory (Help.data_dir, level.json) next to lesson progress; a
      # level saved by the older check (the tone's peak, up to -3 dBFS,
      # i.e. a trim up to +27 dB) loads as its trim, at most 0 dB, with a
      # notice once.
      #
      # Example (bin/sound.rb):
      #     help.level          # the level check (keys: up/down 3 dB, left/right 1 dB, Enter, q)
      #     help.level -12.db   # or set the trim directly (the tone then peaks at -42 dBFS)
      #     monitor_gain.to_db  # the trim it set (-12 here)
      module Level
        # The level check tone's peak at the output (dBFS) at a trim of
        # 0 dB, and the level examples are written for.
        REFERENCE_DB = -30.0

        # The trims (dB) the level check allows: down to -60, up to 0 (the
        # trim only attenuates; see Session::MonitorTrim).
        RANGE = -60.0..0.0

        # What the level check says at 0 dB.
        LOUDER = 'For more level, raise the system or audio interface volume (the trim only turns down)'

        # How far an example may peak over the level check tone (the guard
        # spec checks it at the reference): at most -21 dBFS at a 0 dB trim.
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

        # The saved level (the trim in dB, in RANGE), or nil before the
        # first level check.  A level the older check saved (the tone's
        # peak in dBFS) reads as its trim, at most 0 dB.
        def saved = read_saved&.first

        def saved? = !saved.nil?

        # [trim dB (in RANGE), the older check's trim it came from or nil]
        # from level.json, or nil.
        def read_saved
          h = JSON.parse(File.read(path))
          return nil unless h.is_a?(Hash)
          if h['trim_db'].is_a?(Numeric)
            [h['trim_db'].to_f.clamp(RANGE.begin, RANGE.end), nil]
          elsif h['db'].is_a?(Numeric)
            ref = h['reference_db'].is_a?(Numeric) ? h['reference_db'].to_f : REFERENCE_DB
            old = h['db'].to_f - ref
            [old.clamp(RANGE.begin, RANGE.end), old]
          end
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        # The listening level (the trim in dB): the saved one, else 0.
        def db = saved || 0.0

        # The monitor trim (linear) for a level of +db+.
        def trim_for(db) = 10 ** (db / 20.0)

        # Saves +db+ (the trim in dB, clamped to RANGE; over 0 dB warns to
        # raise the system volume instead) and sets the monitor trim from
        # it; returns the saved value.
        def save(db)
          raise ArgumentError, "The level must be a number of dB (got #{db.inspect})" unless db.is_a?(Numeric)
          warn format("\e[33mLevel %+.1f dB asked: 0 dB is the most.  %s\e[0m", db, LOUDER) if db > RANGE.end
          write(db.to_f.clamp(RANGE.begin, RANGE.end))
          apply
          saved
        end

        # Sets the monitor trim from the saved level (bin/sound.rb at
        # startup); leaves it alone if there is none.  A level the older
        # check saved is rewritten as its trim, with a notice (once) when
        # it was over 0 dB.  Returns the trim.
        def apply
          db, old = read_saved
          return Session.monitor_gain if db.nil?
          if old
            write(db)
            if old > RANGE.end
              warn format(
                "\e[33mYour saved listening level was a monitor trim of %+.1f dB, which clipped live output over %.0f dBFS; " \
                "it is 0 dB now (the trim only turns down).  %s, or help.level to check it again\e[0m",
                old, -old, LOUDER
              )
            end
          end
          Session.monitor_gain = trim_for(db)
          Session.monitor_gain
        end

        def write(db)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate('trim_db' => db, 'tone_peak_db' => REFERENCE_DB + db, 'saved' => Time.now.utc.to_s))
        end

        # The level check tone at full scale (peak 1): a soft A3 triangle
        # swelling once a second.
        def signal
          220.hz.triangle * (0.75.constant + 1.hz.lfo * 0.25)
        end

        # Plays the level check tone through a Session at the reference peak
        # (before the trim) and moves the monitor trim to the asked level
        # (dB), so the output peaks at REFERENCE_DB plus it in a Session
        # that applies the trim (a realtime one, or +monitor: true+).  #stop
        # restores the trim it found.
        class SessionPlayer
          def initialize(session = Session.current)
            @session = session
            @old_trim = nil
          end

          # Opens the sound card (raises DeviceOutput::Unavailable without
          # one) before anything is printed.
          def prepare
            @session.output
            self
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
            @louder = false
            @stopped = false
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
              @out.puts "#{c(:ok, '✓')} monitor trim #{fmt(@db, sign: true)} dB for live playback (the tone at #{fmt(REFERENCE_DB + @db)} dBFS; renders unchanged); #{code('help.level')} to change it"
              @db
            else
              @out.puts c(:dim, "level unchanged (monitor trim #{fmt(Level.db, sign: true)} dB)")
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
              move_to(RANGE.end)
            elsif (step = KEYS[k])
              @louder = step > 0 && @db >= RANGE.end
              move_to(@db + step)
              return nil
            end
            @louder = false
            nil
          end

          # The status line (without the carriage return).
          def status
            pos = (@db - RANGE.begin) / (RANGE.end - RANGE.begin)
            n = 24
            full = (pos * n).round
            hint = @louder ? c(:warn, "0 dB is the most: #{LOUDER.sub(/\AFor more level, r/, 'r')}") : c(:dim, '↑↓ 3 dB  ←→ 1 dB  r reset  Enter keep  q cancel')
            "#{c(:key, format('%6s dB', fmt(@db, sign: true)))} #{c(:dim, format('(%s dBFS)', fmt(REFERENCE_DB + @db)))} " \
              "#{c(:bar, '▕' + '█' * full + '·' * (n - full) + '▏')} #{hint}"
          end

          private

          def intro
            [
              "#{c(:title, 'level check')} #{c(:dim, "a soft tone at #{fmt(REFERENCE_DB + @db)} dBFS")}",
              wrap('Turn it down until it is comfortable, about as loud as you would like to hear mb-sound; Enter keeps it.  ' \
                   'This sets a monitor trim for live playback only, from -60 dB to 0 dB (renders and recordings are unchanged).  ' \
                   'The trim only turns down, so live output never clips from it: if the tone is too quiet at 0 dB, ' \
                   'raise your system or audio interface volume instead.', indent: 2),
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
            sign && v > 0 ? "+#{s}" : s
          end
        end
      end
    end
  end
end
