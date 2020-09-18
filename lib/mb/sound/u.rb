require 'io/console'
require 'word_wrap'

module MB
  module Sound
    # General purpose utility functions, e.g. for dealing with the display.
    #
    # Most things in here should eventually be moved elsewhere as better
    # abstractions are discovered.
    module U
      # The width of the terminal window, defaulting to 80 if the width can't
      # be determined.
      def self.width
        IO.console.winsize&.last || ENV['COLUMNS']&.to_i || 80
      end

      # Wraps the given text for the current terminal width, or 80 columns if
      # the terminal width is unknown.
      def self.wrap(text)
        WordWrap.ww(text, width - 1, true)
      end

      # Returns a String with a syntax highlighted form of the given +object+,
      # using Pry's ColorPrinter.  If the ColorPrinter is not available,
      # CodeRay will be used, and failing that, the string will be bolded.
      def self.highlight(object, columns: nil)
        require 'pry'
        Pry::ColorPrinter.pp(object, '', columns || width)
      rescue LoadError
        begin
          require 'coderay'
          CodeRay.scan(object.inspect, :ruby).terminal
        rescue LoadError
          "\e[1m#{object.inspect}\e[0m"
        end
      end
    end
  end
end
