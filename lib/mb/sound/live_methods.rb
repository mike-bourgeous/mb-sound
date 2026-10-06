module MB
  module Sound
    # Live mode: in the interactive console (bin/sound.rb, which turns it
    # on), mistakes that raise in scripts and specs only print a warning, so
    # a live set keeps playing.  Code that rejects a change calls
    # #live_error with the exception it would raise; outside live mode it
    # raises as usual, in live mode it warns and returns nil, and the caller
    # skips the change.
    #
    # Example (bin/sound.rb):
    #     MB::Sound.live = true
    #     t = 220.hz.saw; play t   # in another thread
    #     t.at(0.5)                # warns: the tone is already playing
    module LiveMethods
      # True in live mode (see LiveMethods).
      def live?
        !!@live
      end

      # Turns live mode on or off.
      def live=(live)
        @live = !!live
      end

      # Raises +error+ (an Exception) unless in live mode; in live mode
      # prints it as a warning and returns nil, so the caller can skip the
      # rejected change and keep playing.
      def live_error(error)
        raise error unless live?

        warn "\e[33m#{error.class}: #{error.message}\e[0m (live mode: ignored)"
        nil
      end
    end
  end
end
