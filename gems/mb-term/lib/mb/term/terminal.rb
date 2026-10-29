require 'io/console'
require_relative '../input/decoder'

module MB
  module Sound
    module UI
      # The real terminal while a screen owns it: the alternate screen, raw
      # input, bracketed paste, optional mouse and focus reports and the
      # kitty keyboard protocol, all undone by #leave (which is safe to call
      # twice, from at_exit, or after an exception), plus feature probes
      # answered through the terminal's replies.  Generic (no MB::Sound
      # types).
      class Term
        # Leaves every mode #enter can set, in reverse: kitty keys, mouse,
        # focus, paste, cursor, colors, the alternate screen.
        LEAVE = "\e[?2026l\e[<u\e[?1006l\e[?1002l\e[?1000l\e[?1004l\e[?2004l\e[0m\e[?25h\e[?1049l".freeze

        attr_reader :input, :output

        # Features found by #probe: :sync (DEC 2026 recognized), :ambiguous
        # (1 or 2 columns), :kitty (the keyboard protocol answered), :device
        # (DA1 answered).  Missing keys were not answered.
        attr_reader :features

        def initialize(input:, output:)
          @input = input
          @output = output
          @entered = false
          @features = {}
        end

        def entered?
          @entered
        end

        # [rows, cols] of the terminal (24x80 if it won't say).
        def size
          s = @output.respond_to?(:winsize) ? @output.winsize : nil
          s && s[0] > 0 && s[1] > 0 ? s : [24, 80]
        rescue SystemCallError, IOError
          [24, 80]
        end

        # Takes the terminal: raw input, the alternate screen, bracketed
        # paste, and the options.  Returns self.
        def enter(mouse: false, focus: false, kitty: false)
          return self if @entered

          @console_mode = @input.console_mode if @input.respond_to?(:console_mode) && @input.tty?
          @input.raw!(intr: false) if @input.respond_to?(:raw!) && @input.tty?
          seq = +"\e[?1049h\e[0m\e[H\e[2J\e[?2004h"
          seq << "\e[?1000h\e[?1002h\e[?1006h" if mouse
          seq << "\e[?1004h" if focus
          seq << "\e[>1u" if kitty
          write(seq)
          @entered = true
          self
        rescue SystemCallError, IOError
          self
        end

        # Gives the terminal back as it was.  Returns self.
        def leave
          return self unless @entered

          @entered = false
          write(LEAVE)
          @input.console_mode = @console_mode if @console_mode
          self
        rescue SystemCallError, IOError
          self
        end

        # Writes bytes (whole, flushed).
        def write(bytes)
          @output.write(bytes)
          @output.flush
        end

        # Asks the terminal about features and waits up to +timeout+
        # seconds for the answers, fenced by a device-attributes query (so
        # a terminal that ignores the others still ends the probe).  Run
        # while entered and before an input reader starts.  Returns
        # #features.
        def probe(timeout: 0.3, glyph: "▽")
          return @features unless @input.respond_to?(:wait_readable) && @input.tty?

          dec = Input::Decoder.new
          dec.expect_cpr = true
          # Ambiguous width: the cursor's column after one ambiguous glyph
          write("\e[1;1H#{glyph}\e[6n\e[1;1H\e[2K\e[?2026$p\e[?u\e[c")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          @skipped = []
          loop do
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if left <= 0 || !@input.wait_readable(left)
            dec.feed(@input.read_nonblock(4096, exception: false).to_s).each do |e|
              case e
              when Input::Reply
                case e.kind
                when :cursor then @features[:ambiguous] = e.data[1] - 1 == 2 ? 2 : 1
                when :mode then @features[:sync] = e.data[1].to_i.between?(1, 4) if e.data[0] == 2026
                when :kitty then @features[:kitty] = true
                when :device then @features[:device] = e.data
                end
              else
                @skipped << e # typed during the probe: handed to the reader
              end
            end
            break if @features.key?(:device)
          end
          @features
        rescue SystemCallError, IOError
          @features
        end

        # Events typed while #probe waited (taken once).
        def typed_during_probe
          s = @skipped || []
          @skipped = []
          s
        end

        # OSC 52: asks the terminal to put +text+ on the system clipboard.
        def copy(text)
          write("\e]52;c;#{[text].pack('m0')}\a")
        end
      end
    end
  end
end
