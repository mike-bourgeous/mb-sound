module MB
  module Sound
    class ScriptRunner
      # Keys and MIDI diagnostics for live synth and effect scripts (ux-1
      # item 19; jack-keyboard drops note-offs when it loses focus, and a
      # stuck note in a live script had no way out but quitting):
      #
      # - Esc: all notes off (sustain pedal up, CC 123 on every channel);
      #   Esc again within a second: all sound off (CC 120: voices cut).
      # - q (or Ctrl-C): quit.
      # - l: the last 20 MIDI events the session read.
      # - MIDI_LOG=1 prints every MIDI event as it arrives;
      #   MIDI_STUCK=seconds warns once per note held longer than that
      #   (a stuck-note watchdog).
      #
      # The messages go into the session's MIDI input through a
      # MIDI::VirtualInput, so synths on live MIDI (the script's, armed
      # monitors) see them as a controller would send them.
      class LiveKeys
        # Seconds within which a second Esc means all sound off.
        DOUBLE_ESC = 1.0

        # MIDI events the l key prints.
        RECENT = 20

        attr_reader :session

        # +out+ where lines go (raw terminal mode: lines end in \r\n);
        # +clock+ monotonic seconds (specs).
        def initialize(session, out: $stdout, clock: nil, log: ENV['MIDI_LOG'].to_s == '1', stuck: ENV['MIDI_STUCK'])
          @session = session
          @out = out
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @log = log
          @stuck = stuck && !stuck.to_s.empty? ? Float(stuck) : nil
          @last_esc = nil
          @virtual = nil
          @seen = session.midi_log_length
          @held = {}
          @warned = {}
        end

        # Sends all notes off (+level+ 1) or all sound off too (+level+ 2)
        # on every channel.  Returns the level.
        def panic(level = 1)
          v = virtual
          16.times do |ch|
            v.cc(64, 0.0, channel: ch)
            v.cc(123, 0.0, channel: ch)
            v.cc(120, 0.0, channel: ch) if level >= 2
          end
          say(level >= 2 ? 'all sound off (CC 120)' : 'all notes off (CC 123; Esc again: all sound off)')
          level
        end

        # Handles one key (a String of what the terminal sent).  Returns
        # :quit, :panic, :sound_off, :log, or nil.
        def key(bytes)
          case bytes
          when "\e"
            now = @clock.call
            if @last_esc && now - @last_esc <= DOUBLE_ESC
              @last_esc = nil
              panic(2)
              :sound_off
            else
              @last_esc = now
              panic(1)
              :panic
            end
          when 'q', 'Q', "\x03" then :quit
          when 'l'
            recent.each { |l| say(l) }
            say('no MIDI yet') if recent.empty?
            :log
          end
        end

        # The last +n+ MIDI events the session read, as text.
        def recent(n = RECENT)
          len = @session.midi_log_length
          @session.midi_log([len - n, 0].max).map { |row| describe(row) }
        end

        # Reads new MIDI from the session's log: prints it with MIDI_LOG=1,
        # and warns about notes held longer than MIDI_STUCK seconds.  Call
        # periodically.
        def poll(now = @clock.call)
          n = @session.midi_log_length
          @seen = n if @seen > n
          if n > @seen
            @session.midi_log(@seen).each do |row|
              say(describe(row)) if @log
              track(row[3], now)
            end
            @seen = n
          end
          return unless @stuck
          @held.each do |k, at|
            next if @warned[k] || now - at < @stuck
            @warned[k] = true
            say("note #{note_name(k[1])} on channel #{k[0] + 1} held #{(now - at).round} s (stuck?  Esc: all notes off)")
          end
        end

        # Runs a key reader on +input+ (a terminal, raw) and the MIDI poll
        # until #stop; q or Ctrl-C raise Interrupt in +main+.
        def start(input: $stdin, main: Thread.main)
          return self unless input.respond_to?(:tty?) && input.tty?
          require 'io/console'
          @input = input
          @mode = input.console_mode rescue nil
          input.raw!(intr: false) rescue nil
          @running = true
          say('keys: Esc all notes off (twice: all sound off), l recent MIDI, q quit')
          @thread = Thread.new do
            Thread.current.name = 'MB::Sound script keys'
            while @running
              poll
              next unless input.wait_readable(0.05)
              data = input.read_nonblock(64, exception: false)
              next unless data.is_a?(String)
              # A lone Esc only (arrow keys and other sequences start with one)
              if data == "\e"
                key(data)
              elsif !data.start_with?("\e")
                data.each_char { |c| main.raise(Interrupt) if key(c) == :quit }
              end
            end
          rescue IOError, SystemCallError
            nil
          end
          self
        end

        def stop
          @running = false
          @thread&.join(0.5)
          @input.console_mode = @mode if @input && @mode
          @virtual&.close if @virtual.respond_to?(:close)
          self
        end

        private

        def say(text)
          @out.write("\r\e[2m#{text}\e[0m\r\n")
        rescue IOError
          nil
        end

        def virtual
          @virtual ||= begin
            v = MIDI::VirtualInput.new('panic')
            src = MIDI::LiveSource.new(v, output: @session.output_open? ? @session.output : nil)
            @session.midi_in.add_source(MIDI::Stream.new(src), label: :panic)
            v
          end
        end

        def track(bytes, now)
          st, d1, d2 = bytes
          return unless st && d1
          ch = st & 0x0F
          case st & 0xF0
          when 0x90
            if d2.to_i > 0
              @held[[ch, d1]] = now
              @warned.delete([ch, d1])
            else
              @held.delete([ch, d1])
            end
          when 0x80 then @held.delete([ch, d1])
          when 0xB0 then (@held.delete_if { |k, _| k[0] == ch } if [120, 123].include?(d1))
          end
        end

        def describe(row)
          name, _epoch, pos, bytes = row
          st, d1, d2 = bytes
          ch = st.to_i & 0x0F
          what =
            case st.to_i & 0xF0
            when 0x90 then d2.to_i > 0 ? "note on  #{note_name(d1)} vel #{d2}" : "note off #{note_name(d1)}"
            when 0x80 then "note off #{note_name(d1)}"
            when 0xB0 then "cc #{d1} = #{d2}"
            when 0xE0 then "bend #{((d2.to_i << 7) | d1.to_i) - 8192}"
            when 0xD0 then "pressure #{d1}"
            else bytes.inspect
            end
          "MIDI #{Session::Stamp.at(pos, @session.transport)} ch #{ch + 1} #{what}#{name ? " (#{name})" : ''}"
        rescue StandardError
          "MIDI #{bytes.inspect}"
        end

        def note_name(n)
          names = %w[C C# D D# E F F# G G# A A# B]
          "#{names[n.to_i % 12]}#{n.to_i / 12 - 1}"
        end
      end
    end
  end
end
