module MB
  module Sound
    # One engine for "below a level for a while, then sleep or end"
    # (node-traits-1, arch-core finding 4): idle Synth lanes, sub-lanes, and
    # drum voices falling asleep, buses sleeping, delays and feedback loops
    # ringing out, ringing tracks (Session::Tails), the master chain's
    # spillover tail, a Synth's end, and the render, wait, and ringdown
    # loops all keep a QuietRun, so the levels, windows, and grid math are
    # written once.
    #
    # A run tracks +quiet_from+, the frame (of the caller's clock) where the
    # current quiet stretch began, and completes once it has lasted
    # +window+ frames.  A sample is loud when its magnitude is at least
    # +loud+ (a float: .float_above gives the smallest float above a level).
    # Modes say where a loud sample moves the start:
    #
    # - +:sample+ (buses, tails, ring-outs, a Synth's end): right after the
    #   loud sample, so the run is frame-exact and the same at any buffer
    #   size.  With a +grid+, the run completes only at grid frames
    #   (buses sleep on Session frames that are multiples of GRID).
    # - +:cells+ (the grid sleepers: Synth lanes, sub-lanes, drum voices):
    #   at the start of the next grid cell, so the run counts whole silent
    #   cells of +grid+ frames; a sleeper falls asleep only at a grid point
    #   ending +window+ / +grid+ silent cells (and only if its nodes' idle
    #   checks agree, see NodeTraits), splitting its buffers there
    #   (#split_point), and resets the run where it wakes (#reset).
    # - +:buffer+ (the master chain's tail, render_tail, wait, the script
    #   ringdown, a drum voice's end): a buffer with any loud sample moves
    #   the start to its end, counting on an internal clock (#advance_buffer);
    #   these decide per buffer, as they always have (making them
    #   frame-exact would move where renders end by up to a buffer).
    #
    # #advance is the ring-out form (delays, multitaps, networks, feedback
    # loops after their input ends): it finds the exact sample where the run
    # completes inside a block, including in a gap between loud samples, on
    # an internal clock.
    class QuietRun
      # The level below which a tail counts as ended or a bus may sleep
      # (-90 dB).
      QUIET = 10.0 ** (-90 / 20.0)

      # The level below which a sleeper's output counts as silent (-120 dB;
      # stricter than QUIET because sleeping replaces the output with
      # zeros).
      SILENCE = 1e-6

      # How long tails (ringing tracks, buses, master chains, renders) must
      # stay below QUIET to count as ended.
      QUIET_SECONDS = 1

      # The sleepers' grid (frames of each sleeper's own time; Session
      # frames for buses): sleepers fall asleep only on its points, so the
      # same frames are skipped at any buffer size.
      GRID = 800

      MODES = %i[sample cells buffer].freeze

      # The smallest float magnitude counted as loud for "above +level+"
      # (a Float compared in double precision): float samples are above
      # +level+ exactly when their magnitude is at least this (the
      # comparison FastArithmetic.last_at_least makes).
      def self.float_above(level)
        f = [level].pack('e').unpack1('e')
        return f if f > level

        [[f].pack('e').unpack1('L') + 1].pack('L').unpack1('e')
      end

      # The smallest float at or above +level+ (for "at least +level+").
      def self.float_at_least(level)
        f = [level].pack('e').unpack1('e')
        return f if f >= level

        [[f].pack('e').unpack1('L') + 1].pack('L').unpack1('e')
      end

      # Loud bounds for QUIET (at least -90 dB: also "above", since no float
      # lies between QUIET and this) and SILENCE (above -120 dB), and for
      # "nonzero" (sub-lanes sleep after exactly silent cells).
      QUIET_LOUD = float_at_least(QUIET)
      SILENCE_LOUD = float_above(SILENCE)
      NONZERO_LOUD = 2.0**-149

      attr_reader :window, :mode, :grid, :quiet_from

      # The run's internal clock (frames advanced by #advance and
      # #advance_buffer).
      attr_reader :at

      # A run of +window+ frames (see the class description) whose quiet
      # stretch starts at frame +from+ (of the caller's clock; the internal
      # clock starts at 0).  +grid+ frames per grid cell, with grid points
      # where (frame + +offset+) is a multiple of +grid+.
      def initialize(window, loud: QUIET_LOUD, mode: :sample, grid: nil, offset: 0, from: 0)
        raise ArgumentError, "Unknown quiet run mode #{mode.inspect} (#{MODES.join(', ')})" unless MODES.include?(mode)
        raise ArgumentError, 'A :cells run needs a grid' if mode == :cells && grid.nil?

        @window = window
        @loud = loud.to_f
        @mode = mode
        @grid = grid
        @offset = offset
        @at = 0
        @done = false
        @range = nil
        @quiet_from = 0
        reset(from)
      end

      # Sets the window (frames).
      attr_writer :window

      # Sets the grid offset (see #initialize).
      attr_writer :offset

      # Starts a new quiet stretch at frame +frame+ (for :cells, the start
      # of the grid cell holding it: a sleeper waking mid-cell counts that
      # cell's rest as a cell).
      def reset(frame)
        @quiet_from = @mode == :cells ? floor_grid(frame) : frame
        @done = false
        self
      end

      # Moves the start of the quiet stretch past the loud samples of
      # +length+ samples of +buf+ from index +from+, the first of them at
      # frame +frame+.  Returns self.
      def track(buf, frame, from = 0, length = buf.length - from)
        return self if length <= 0
        # (cells: nothing in these frames can move the start further, e.g. a
        # sleeper whose current cell is already loud)
        return self if @mode == :cells && floor_grid(frame + length - 1) + @grid <= @quiet_from

        i = last_loud(buf, from, length)
        mark_loud(frame + i) if i
        self
      end

      # #track for each buffer of +bufs+ (channels of the same frames).
      def track_all(bufs, frame, from = 0, length = nil)
        i = 0
        while i < bufs.length
          b = bufs[i]
          track(b, frame, from, length || (b.length - from))
          i += 1
        end
        self
      end

      # Notes a loud sample at frame +frame+ (see the modes).
      def mark_loud(frame)
        q = @mode == :cells ? floor_grid(frame) + @grid : frame + 1
        @quiet_from = q if q > @quiet_from
        self
      end

      # The frame where the run completes if nothing loud comes first: the
      # start plus the window (with a grid, the first grid point there or
      # later).
      def ends_at
        e = @quiet_from + @window
        e = e.ceil if e.is_a?(Float)
        @grid ? ceil_grid(e) : e
      end

      # Frames the stretch has lasted at frame +frame+.
      def quiet_for(frame)
        frame - @quiet_from
      end

      # True if the run is complete at frame +frame+ (with a grid, only at
      # grid points).
      def complete_at?(frame)
        return false if @grid && !on_grid?(frame)

        frame - @quiet_from >= @window
      end

      # The earliest frame after +frame+ where the run could complete if
      # nothing loud comes first (a grid point with a grid).
      def next_point(frame)
        e = ends_at
        e = frame + 1 if e <= frame
        @grid ? ceil_grid(e) : e
      end

      # Where a sleeper at frame +pos+ (offset 0 of a block of +count+)
      # should end the piece of the block starting at offset +o+: the offset
      # of #next_point, or +count+ if that is past the block.
      def split_point(pos, o, count)
        g = next_point(pos + o) - pos
        g > count ? count : g
      end

      # True if a grid point +frame+ completes the run (a sleeper may fall
      # asleep there, if its idle checks agree).
      def sleep_due?(frame)
        complete_at?(frame)
      end

      # True if a grid point is at frame +frame+.
      def on_grid?(frame)
        (frame + @offset) % @grid == 0
      end

      # The ring-out form (see the class description): advances the internal
      # clock over the +count+ samples a node wrote (an NArray, or nil if
      # they were all silent) with the given +window+ (in samples; defaults
      # to the run's).  Returns nil if the run goes on past them, or the
      # number of these samples to keep (1..count) if the run completes
      # within them (#done? is then true).
      def advance(written, count, window = @window)
        raise 'This run has already completed' if @done

        window = window.ceil
        window = 1 if window < 1
        start = @at
        run = start - @quiet_from
        @at = start + count

        loud = written.nil? ? nil : loud_indices(written)
        if loud.nil? || loud.empty?
          return finish(window - run) if run + count >= window

          return nil
        end

        # The gap before the first loud sample
        first = loud[0]
        return finish(window - run) if run + first >= window

        # Gaps between loud samples
        if loud.length > 1
          gaps = loud.diff - 1
          idx = (gaps >= window).where
          return finish(loud[idx[0]] + 1 + window) unless idx.empty?
        end

        # The gap after the last loud sample
        last = loud[-1]
        return finish(last + 1 + window) if count - last - 1 >= window

        @quiet_from = start + last + 1
        nil
      end

      # The buffer form (see the class description): advances the internal
      # clock over a buffer of +count+ frames that was +loud+ (true if any
      # sample was).  Returns true once the run is complete.
      def advance_buffer(count, loud)
        @at += count
        @quiet_from = @at if loud
        @done = @at - @quiet_from >= @window
      end

      # True once #advance found the run's end, or #advance_buffer's run is
      # complete.
      def done?
        @done
      end

      # True if any of +length+ samples of +buf+ from +from+ is loud.
      def loud?(buf, from = 0, length = buf.length - from)
        !last_loud(buf, from, length).nil?
      end

      private

      def finish(keep)
        @done = true
        keep
      end

      # The index (from +from+) of the last loud one of +length+ samples of
      # +buf+, or nil.
      def last_loud(buf, from, length)
        i = MB::Sound::Kernels.last_at_least(buf, from, length, @loud)
        return (i < 0 ? nil : i) if i

        x = from == 0 && length == buf.length ? buf : buf[from...(from + length)]
        x = x.abs if x.is_a?(Numo::SComplex) || x.is_a?(Numo::DComplex)
        idx = x.abs.ge(@loud).where
        idx.length > 0 ? idx[-1] : nil
      end

      # The loud indices of +written+ (for #advance).
      def loud_indices(written)
        r = (@range ||= [0.0, 0.0])
        if MB::Sound::Kernels.min_max(written, r)
          return nil if r[1] < @loud && -r[0] < @loud
        end
        written = written.abs if written.is_a?(Numo::SComplex) || written.is_a?(Numo::DComplex)
        written.abs.ge(@loud).where
      end

      def floor_grid(frame)
        g = @grid or return frame
        ((frame + @offset) / g) * g - @offset
      end

      def ceil_grid(frame)
        g = @grid
        ((frame + @offset + g - 1) / g) * g - @offset
      end
    end
  end
end
