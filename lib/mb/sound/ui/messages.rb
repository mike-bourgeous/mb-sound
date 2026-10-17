module MB
  module Sound
    module UI
      # Warnings and live errors while a UI screen is up (ux-1 item 11;
      # maintainer: "warnings should show up in a separate panel when the
      # UI is up"): Ruby's Warning.warn (so `warn`, MB::Sound.live_error,
      # and the monitor trim's clip warning) is recorded here, deduplicated
      # by text with counts, and shown in the :messages pane, as a count on
      # the tiles' status line (NAV m shows the pane), and as a summary
      # when the UI turns off.  While a screen owns the real terminal (a
      # band on a terminal, the tiles' adopted console) warnings are not
      # printed, so they can't tear the screen; otherwise (specs, a band
      # drawn elsewhere) they print as usual too.
      #
      #     UI.messages.recent(5)     # the newest entries
      #     UI.messages.summary       # what ui off prints
      class Messages
        # One message: its text (one line, no escapes), severity (:warn,
        # :error, :note), how many times it came, when first and last
        # (monotonic seconds), and its sequence number when it last came.
        Entry = Struct.new(:text, :severity, :count, :first, :last, :seq)

        # Distinct messages kept (the oldest go first).
        LIMIT = 200

        def initialize
          @lock = Mutex.new
          @entries = {}
          @seq = 0
          @read = 0
          @total = 0
        end

        # Sequence number of the newest message (0: none yet).
        def seq = @lock.synchronize { @seq }

        # Messages received in all (repeats included).
        def total = @lock.synchronize { @total }

        # Messages that came since #mark_read (repeats included).
        def unread = @lock.synchronize { @entries.each_value.count { |e| e.seq > @read } }

        # Records +text+ (ANSI escapes and surrounding space removed;
        # repeats count).  Returns the Entry.
        def add(text, severity: :warn, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
          t = text.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, '').strip.gsub(/\s*\n\s*/, ' / ')
          return nil if t.empty?

          @lock.synchronize do
            @seq += 1
            @total += 1
            e = @entries.delete(t)
            if e
              e.count += 1
              e.last = now
              e.seq = @seq
              e.severity = severity if severity == :error
            else
              e = Entry.new(t, severity, 1, now, now, @seq)
            end
            @entries[t] = e
            @entries.delete(@entries.each_key.first) while @entries.length > LIMIT
            e
          end
        end

        # The newest +n+ entries, newest first (copies).
        def recent(n = 10)
          @lock.synchronize { @entries.values.last(n).reverse.map(&:dup) }
        end

        # Marks everything read (the status line's count goes away).
        def mark_read
          @lock.synchronize { @read = @seq }
          self
        end

        def clear
          @lock.synchronize do
            @entries.clear
            @read = @seq
            @total = 0
          end
          self
        end

        # Lines summarizing what came (for `ui off`), or nil if nothing did.
        def summary(limit: 5)
          list = recent(limit)
          return nil if list.empty?
          n = total
          distinct = @lock.synchronize { @entries.length }
          head = "ui: #{n} message#{'s' unless n == 1}#{distinct < n ? " (#{distinct} different)" : ''} while the UI was up#{distinct > limit ? "; the newest #{limit}" : ''}:"
          [head, *list.map { |e| "  #{e.count > 1 ? "×#{e.count} " : ''}#{e.text}" }].join("\n")
        end

        # Takes the place of $stdout while a screen without a console is up
        # (a script's --ui): lines printed go to the messages as :note.
        class Writer
          def initialize(messages, real)
            @messages = messages
            @real = real
            @partial = +''
          end

          def write(*parts)
            text = parts.join
            @partial << text
            while (i = @partial.index("\n"))
              line = @partial.slice!(0..i)
              @messages.add(line, severity: :note)
            end
            text.bytesize
          end

          def <<(text)
            write(text)
            self
          end

          def puts(*lines)
            lines = [''] if lines.empty?
            lines.flatten.each { |l| write("#{l.to_s.chomp}\n") }
            nil
          end

          def print(*parts) = write(*parts) && nil
          def printf(*args) = write(format(*args)) && nil
          def flush = self
          def sync = true
          def sync=(_v); end
          def tty? = false
          def isatty = false
          def fileno = @real.fileno
          def winsize = @real.winsize
        end

        # The severity of a warning: :error for live errors, :note for
        # :deprecated and :performance categories, else :warn.
        def self.severity_of(msg, category = nil)
          return :note if %i[deprecated performance].include?(category)
          msg.to_s.include?('(live mode: ignored)') ? :error : :warn
        end

        # Prepended to Warning's singleton class (UI.install_messages!):
        # records warnings while a screen is up, printing them only when
        # no screen owns the real terminal.
        module WarningHook
          def warn(msg, category: nil, **kw)
            if UI.screen
              UI.messages.add(msg, severity: Messages.severity_of(msg, category))
              return nil if UI.owns_terminal?
            end
            super
          end
        end
      end

      class << self
        # The messages recorded while a screen was up (see Messages).
        def messages
          @messages ||= Messages.new
        end

        # Hooks Warning.warn (once).
        def install_messages!
          return if @messages_installed
          Warning.singleton_class.prepend(Messages::WarningHook)
          @messages_installed = true
        end

        # True when the screen on owns the process's real terminal, so
        # anything printed to stderr would land in it.
        def owns_terminal?
          s = screen
          return false unless s
          s.respond_to?(:owns_terminal?) && s.owns_terminal?
        end
      end
    end
  end
end
