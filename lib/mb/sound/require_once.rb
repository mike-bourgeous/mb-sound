module MB
  module Sound
    # Makes `require` of a feature that is already loaded return at once,
    # without searching the load path (gvl-main-1, 2026-11-21).
    #
    # Ruby looks a feature up again on every `require` when it was loaded
    # from a C extension: `require 'io/console'` checks each load path
    # directory before the extension's for an io/console.rb that would
    # shadow it, with open() calls made while the thread holds the GVL.
    # Pry calls `require 'io/console'` (and pp.rb's width check another)
    # every time it prints a result, so every console line did it.  Where
    # the checkout is on a network file system (the Linux desktop's sshfs
    # mount of the Mac's tree) each failed open is a round trip: the
    # maintainer's console held the GVL 24-135 ms per line, and the render
    # thread, waiting for it, ran the queue dry (four dropouts in nine
    # minutes; 9-10 ms per require, up to 112 ms, measured from the
    # container with the mount's directories first on the load path).
    #
    # Installed by the console (bin/sound.rb; .install): Kernel#require
    # gains a check of the features it has already required.  The first
    # require of a feature runs as before (RubyGems, Bundler, autoload);
    # later ones of the same name return false.  mb-sound's own features
    # (mb/...) are never kept (Library::Bench reloads another checkout's),
    # and the list starts over when $LOADED_FEATURES shrinks.
    module RequireOnce
      @done = {}
      @seen = 0

      # Prepended to Kernel by .install.
      module Hook
        private

        def require(path)
          return false if RequireOnce.done?(path)

          result = super
          RequireOnce.note(path)
          result
        end
      end

      # Features required again at run time by code the console runs (Pry's
      # and pp's width checks, Reline): looked up once by .install.
      PRELOAD = %w[io/console io/wait stringio strscan].freeze

      class << self
        # Prepends Hook to Kernel (once) and requires PRELOAD through it.
        # Returns true, or false with MB_SOUND_REQUIRE_ONCE=0 (nothing
        # installed: for comparisons).
        def install
          return false if ENV['MB_SOUND_REQUIRE_ONCE'] == '0'

          Kernel.prepend(Hook) unless Kernel.ancestors.include?(Hook)
          PRELOAD.each { |f| require f }
          true
        end

        # True if Hook is installed.
        def installed? = Kernel.ancestors.include?(Hook)

        # True if +path+ (a feature name) was required before and is still
        # loaded.
        def done?(path)
          return false unless path.is_a?(String)

          n = $LOADED_FEATURES.length
          if n < @seen
            @done = {}
            @seen = n
            return false
          end
          @done.key?(path)
        end

        # Notes +path+ as required (Hook, after a require returns).
        def note(path)
          return unless path.is_a?(String) && !path.start_with?('mb/', 'mb-', '/', '.')

          @done[path] = true
          @seen = $LOADED_FEATURES.length
        end

        # Forgets every feature noted (specs).
        def reset
          @done = {}
          @seen = 0
        end
      end
    end
  end
end
