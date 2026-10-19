require 'io/console'

module MB
  module Sound
    # What the console knows about the terminal it runs in, for debug_dump
    # and bug reports (maintainer, 2026-10-18: the terminal program's name
    # and version "if it can be found without a crazy amount of code or
    # chicanery"): environment variables terminals set, and the XTVERSION
    # answer (CSI > 0 q; xterm, kitty, WezTerm, foot, Konsole, ...), asked
    # once at startup when stdin and stdout are a terminal (.query!).
    module TerminalInfo
      # Environment variables that name or describe the terminal.
      ENV_KEYS = %w[
        TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM KONSOLE_VERSION VTE_VERSION KITTY_WINDOW_ID
        WEZTERM_EXECUTABLE WT_SESSION ALACRITTY_SOCKET TMUX STY SSH_TTY LANG LC_ALL
      ].freeze

      # XTVERSION's reply: DCS > | text ST.
      XTVERSION_REPLY = /\eP>\|([^\e]*)\e\\/n

      # A DA1 reply, which fences the query (every terminal answers it).
      DA1_REPLY = /\e\[\?[\d;]*c/n

      @version = nil
      @queried = false
      @no_tty = false

      class << self
        # The XTVERSION answer (e.g. "Konsole 24.08.1"), nil if not asked
        # or not answered.
        attr_reader :version

        # True once .query! asked (or decided not to).
        def queried? = @queried

        # Asks the terminal its name and version (XTVERSION, fenced by DA1)
        # and waits up to +timeout+ seconds, once per process; only when
        # +input+ and +output+ are terminals.  Bytes typed meanwhile go back
        # to +input+.  Returns .version.
        def query!(input: $stdin, output: $stdout, timeout: 0.2)
          return @version if @queried

          @queried = true
          @no_tty = !(input.respond_to?(:tty?) && input.tty? && output.respond_to?(:tty?) && output.tty?)
          return nil if @no_tty

          buf = +''.b
          input.raw(intr: true) do
            output.write("\e[>0q\e[c")
            output.flush
            deadline = MB::U.clock_now + timeout
            until buf.match?(DA1_REPLY)
              left = deadline - MB::U.clock_now
              break if left <= 0 || !input.wait_readable(left)
              buf << input.read_nonblock(4096, exception: false).to_s.b
            end
          end
          @version = buf[XTVERSION_REPLY, 1]&.dup&.force_encoding('UTF-8')&.scrub
          rest = buf.sub(XTVERSION_REPLY, '').sub(DA1_REPLY, '')
          input.ungetbyte(rest) unless rest.empty?
          @version
        rescue SystemCallError, IOError
          @version
        end

        # Sets the version (specs, or a probe made elsewhere).
        def version=(v)
          @queried = true
          @version = v
        end

        # The report's lines: the XTVERSION answer, the terminal's size,
        # and the environment variables of ENV_KEYS that are set.
        def report(output: $stdout, env: ENV)
          size = output.respond_to?(:winsize) && output.tty? ? output.winsize : nil rescue nil
          [
            "Terminal:     #{@version || (@no_tty ? 'not asked (stdin or stdout is not a terminal)' : @queried ? 'no XTVERSION answer' : 'not asked (bin/sound.rb asks at startup)')}",
            "Size:         #{size ? "#{size[0]} rows x #{size[1]} columns" : 'unknown'}",
            "Environment:  #{ENV_KEYS.filter_map { |k| "#{k}=#{env[k]}" if env[k] }.join(' ')}",
          ].join("\n")
        end
      end
    end
  end
end
