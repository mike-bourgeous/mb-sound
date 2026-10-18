module MB
  module Sound
    # The one decision on whether mb-sound prints color (ux-fix-1,
    # 2026-10-18): help pages, `now`, tables, console errors, script logs
    # and parameter lists, and the console all ask .color?.  Color is off
    # when the output isn't a terminal (a pipe or a log file), NO_COLOR is
    # set (https://no-color.org), or TERM is dumb; FORCE_COLOR (non-empty,
    # not 0) turns it on anyway, e.g. for `less -R`.
    #
    # Code printed by other libraries (Pry, mb-util's highlighting, bin/
    # scripts' own escapes) is covered by .strip_output!, which bin/sound.rb
    # and ScriptRunner call when color is off: SGR color codes written to
    # $stdout and $stderr are removed.
    module ColorPolicy
      # SGR (color and style) escape sequences.
      SGR = /\e\[[0-9;:]*m/

      # Removes SGR sequences from everything written to an IO (see
      # .strip_output!).
      module Stripping
        def write(*args)
          super(*args.map { |a| a.is_a?(String) ? a.gsub(SGR, '') : a.to_s.gsub(SGR, '') })
        end
      end

      module_function

      # True if text printed to +io+ may be colored (see the module
      # description).  +env+ is for specs.
      def color?(io = $stdout, env: ENV)
        force = env['FORCE_COLOR'].to_s
        return true unless force.empty? || force == '0'
        return false unless env['NO_COLOR'].to_s.empty?
        return false if env['TERM'] == 'dumb'

        io.respond_to?(:tty?) && io.tty?
      rescue IOError
        false
      end

      # +text+ without SGR color codes.
      def strip(text)
        text.to_s.gsub(SGR, '')
      end

      # +text+ as it should print to +io+: unchanged if .color?, else
      # stripped.
      def for_output(text, io = $stdout)
        color?(io) ? text : strip(text)
      end

      # Makes each of +ios+ (default $stdout and $stderr) for which .color?
      # is false drop SGR codes from what is written to it.  Returns the
      # IOs changed.  Idempotent.
      def strip_output!(ios = [$stdout, $stderr])
        ios.reject { |io| color?(io) }.each do |io|
          io.singleton_class.prepend(Stripping) unless io.singleton_class.include?(Stripping)
        end
      end
    end
  end
end
