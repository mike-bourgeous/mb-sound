module MB
  module Sound
    # Keeps Ruby's GC from starting a major (full) collection while a
    # scene builds (alloc-2, 2026-10-25).
    #
    # A scheduled block builds the next scene's graphs on the scheduler
    # thread, allocating a burst of objects; when a minor collection then
    # finds the heap full, Ruby starts a major one (GC.latest_gc_info
    # major_by: :nofree), which stops every thread, the render thread too,
    # for 45-80 ms in the container (YJIT's code roots ~15 ms of it), and
    # up to 174 ms in memory_card's "lift ends" build.  While any block
    # runs inside .during, GC.config(rgengc_allow_full_mark: false) makes
    # Ruby grow the heap instead; objects made meanwhile stay young (not
    # promoted, so minors mark them) until the last block ends, when the
    # setting goes back.  Majors still run when Ruby wants one outside
    # builds.
    #
    # MB_SOUND_GC_QUIET=0 turns it off (for A/B measurements).
    #
    # .hold (the console's `gc :quiet`; session-2, the maintainer's
    # "Console switch", 2026-10-30) holds majors off for a whole live set,
    # until .release (`gc :normal`): nothing made meanwhile is promoted, so
    # memory grows (about 1-2 MB/s while playing; arrangement.md measured
    # 0.73 MB/s on night_bus_flow) and minors slow as young objects pile
    # up, but no major can stop the render thread.  Off by default.
    module GCQuiet
      ENABLED = !%w[0 false off no].include?(ENV['MB_SOUND_GC_QUIET'].to_s.downcase) && GC.respond_to?(:config)

      @mutex = Mutex.new
      @depth = 0
      @before = nil
      @held = nil # (the process clock and RSS when .hold began, or nil)

      class << self
        # Runs the block with major collections held off (see GCQuiet).
        def during
          return yield unless ENABLED

          enter
          begin
            yield
          ensure
            leave
          end
        end

        # True while some block is inside .during, or while held.
        def active?
          @depth > 0
        end

        # Holds major collections off until .release (see GCQuiet).
        # Returns true if this call started the hold, false if it was held
        # already or GCQuiet is off.
        def hold
          return false unless ENABLED
          @mutex.synchronize { return false if @held }
          enter
          @mutex.synchronize { @held = [MB::U.clock_now, GCQuiet.rss_mb] }
          true
        end

        # Ends .hold, letting majors run again.  Returns true if it was held.
        def release
          held = @mutex.synchronize { h = @held; @held = nil; h }
          return false unless held
          leave
          true
        end

        # True while .hold is in effect.
        def held?
          !@held.nil?
        end

        # How long the hold has lasted (seconds) and how much the process's
        # resident memory grew meanwhile (MB, nil where it can't be read),
        # or nil if not held.
        def held_for
          start, rss = @held || (return nil)
          now_rss = rss_mb
          [MB::U.clock_now - start, rss && now_rss ? now_rss - rss : nil]
        end

        # One line describing the mode (the console's `gc`, also shown by
        # `now` while held).
        def status
          held = held_for or return 'gc normal (majors allowed; `gc :quiet` holds them off for a set)'
          seconds, grown = held
          grew = grown ? format(', memory %+.0f MB since', grown) : ''
          "gc quiet for #{seconds.round}s#{grew} (no majors; memory grows about 1-2 MB/s while playing until `gc :normal`)"
        end

        # The process's resident memory in MB (Linux /proc), or nil.
        def rss_mb
          line = File.foreach('/proc/self/status').find { |l| l.start_with?('VmRSS:') } or return nil
          line.split[1].to_f / 1024
        rescue SystemCallError
          nil
        end

        private

        def enter
          @mutex.synchronize {
            if @depth == 0
              @before = GC.config[:rgengc_allow_full_mark]
              GC.config(rgengc_allow_full_mark: false) if @before
            end
            @depth += 1
          }
        end

        def leave
          @mutex.synchronize {
            @depth -= 1
            GC.config(rgengc_allow_full_mark: true) if @depth == 0 && @before
          }
        end
      end
    end
  end
end
