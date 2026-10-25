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
    module GCQuiet
      ENABLED = !%w[0 false off no].include?(ENV['MB_SOUND_GC_QUIET'].to_s.downcase) && GC.respond_to?(:config)

      @mutex = Mutex.new
      @depth = 0
      @before = nil

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

        # True while some block is inside .during.
        def active?
          @depth > 0
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
