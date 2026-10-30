module MB
  module Sound
    # The circular buffer behind every delay (Filter::Delay and
    # GraphNode::MultitapDelay): write a block of input, then read it back
    # at a constant delay or a delay per sample, or run input through a
    # feedback loop one sample at a time.
    #
    # Delays are in samples, counted back from each output sample's own
    # input sample: after writing a block, output sample i of a read at
    # delay d is the input from d samples before input sample i (so a delay
    # of 0 returns the block itself).  Delays are clamped to 0 and to the
    # buffer's capacity.
    #
    # Fractional delays interpolate with one of the INTERPOLATION modes:
    # - :linear: between the two nearest samples.  Cheapest, but its high
    #   frequencies dull and flutter as the fraction changes, and it
    #   aliases when a moving delay raises the pitch.
    # - :cubic: a 4-point Catmull-Rom (Hermite) spline.  Much less dulling
    #   and flutter; still aliases when raising the pitch.
    # - :sinc: a Kaiser-windowed sinc (SINC_KERNEL).  Flat to near Nyquist,
    #   and when a moving delay reads faster than 1x (raising the pitch) its
    #   cutoff drops by the read speed (up to SINC_MAX_RATE), removing the
    #   frequencies that would alias.
    # A whole-sample delay that isn't moving faster than 1x reads the sample
    # directly in every mode, so constant delays cost the same in all modes.
    # No mode reads samples newer than the current input sample: taps that
    # would be newer read the current sample, so very short delays (under
    # SINC_HALF samples for :sinc) are interpolated less accurately.
    #
    # #read runs in C (MB::Sound::FastDelay.read, in the fast_delay
    # extension); #read_ruby is the same math in Ruby, and specs check that
    # both give exactly the same values.  Delays with feedback are feedback
    # loops (GraphNode::FeedbackLoop, fast_loop, reading lines like #read)
    # or delay networks (.network).
    #
    # The buffer grows when a block plus the longest delay doesn't fit
    # (see #prepare), keeping the stored audio: growing unwraps it oldest
    # first, so delays read the same samples afterwards.  Growing allocates
    # memory, so size the buffer for the longest delay up front for live
    # use.
    class DelayLine
      # Interpolation modes for fractional delays (see the class
      # description), as numbered by the C kernels.
      INTERPOLATION = { linear: 0, cubic: 1, sinc: 2 }.freeze

      # The interpolation mode delays use unless given one: :sinc, which
      # costs about 1.5-2% of realtime per moving or fractional mono delay
      # at 48 kHz (constant whole-sample delays cost the same as :linear).
      DEFAULT_INTERPOLATION = :sinc

      # Taps on each side of the sinc kernel's center at full bandwidth.
      SINC_HALF = 12

      # Kaiser window shape for the sinc kernel (higher: lower sidelobes,
      # wider transition band).
      SINC_BETA = 6.0

      # Sinc kernel table entries per sample.
      SINC_RESOLUTION = 512

      # The fastest read speed the sinc kernel low-passes for; faster reads
      # alias (the kernel would get too long).
      SINC_MAX_RATE = 4.0

      # Returns the zeroth-order modified Bessel function of the first kind
      # (for the Kaiser window).
      def self.bessel_i0(x)
        sum = 1.0
        term = 1.0
        k = 1
        loop do
          term *= (x / (2.0 * k)) ** 2
          sum += term
          break if term < sum * 1e-17
          k += 1
        end
        sum
      end

      # Returns the sinc kernel table: the Kaiser-windowed sinc at
      # j / SINC_RESOLUTION samples from its center, 0 past SINC_HALF.
      def self.sinc_table(half: SINC_HALF, beta: SINC_BETA, resolution: SINC_RESOLUTION)
        i0_beta = bessel_i0(beta)
        Numo::DFloat.zeros(half * resolution + 2).map_with_index { |_, j|
          u = j.to_f / resolution
          if u >= half
            0.0
          elsif u == 0
            1.0
          else
            sinc = Math.sin(Math::PI * u) / (Math::PI * u)
            sinc * bessel_i0(beta * Math.sqrt(1.0 - (u / half) ** 2)) / i0_beta
          end
        }
      end

      # The sinc kernel given to the C kernels: [table, half, resolution,
      # max rate].
      SINC_KERNEL = [sinc_table.freeze, SINC_HALF, SINC_RESOLUTION, SINC_MAX_RATE].freeze

      # The most samples older than floor(delay) that any mode reads.
      MARGIN = (SINC_HALF * SINC_MAX_RATE).ceil + 2

      # Returns a filter that smooths delay times (in samples) for the
      # +smoothing+ setting of a delay: nil for false, a given Filter as is,
      # or a LinearFollower letting the delay change at most +smoothing+
      # seconds per second (Filter::Delay::DEFAULT_SMOOTHING_RATE for true).
      def self.smoother(smoothing, sample_rate)
        return nil unless smoothing
        return smoothing if smoothing.respond_to?(:process) && smoothing.respond_to?(:reset)

        limit = sample_rate * (smoothing.is_a?(Numeric) ? smoothing : MB::Sound::Filter::Delay::DEFAULT_SMOOTHING_RATE)
        MB::Sound::Filter::LinearFollower.new(sample_rate: sample_rate, max_rise: limit, max_fall: limit)
      end

      # Returns the smoother for a +smoothing+ setting (as for .smoother)
      # after a sample rate change from +old_rate+ to +new_rate+, given the
      # current smoother +filter+.
      #
      # The delays being smoothed are in samples, so a rate in seconds per
      # second is the same number of delay samples per sample at any sample
      # rate.  A LinearFollower built by .smoother is therefore rebuilt for
      # the new rate (moving it with #at_rate would keep its limit in delay
      # samples per second, slowing the glide in seconds per second), with
      # its output moved to the same delay in seconds.  A Filter given as
      # +smoothing+ is moved with #at_rate (right for linear filters such as
      # a lowpass, whose cutoff is in Hz).
      def self.rescale_smoother(filter, smoothing, old_rate, new_rate)
        return nil unless filter

        if smoothing.respond_to?(:process) && smoothing.respond_to?(:reset)
          raise "Filter #{filter} does not support changing sample rate" unless filter.respond_to?(:at_rate)
          return filter.at_rate(new_rate)
        end

        new_filter = smoother(smoothing || true, new_rate)
        new_filter.reset(filter.peek * new_rate / old_rate) if filter.respond_to?(:peek)
        new_filter
      end

      # Smooths +delays+ (an NArray of delays in samples) with +filter+ (from
      # .smoother), skipping a LinearFollower that has settled on a constant
      # delay (it would output the delay unchanged).  Returns the smoothed
      # delays.
      def self.smooth(filter, delays)
        if filter.is_a?(MB::Sound::Filter::LinearFollower)
          min, max = delays.minmax
          return delays if min == max && min == filter.peek
        end

        filter.process(delays.dup.inplace).not_inplace!
      end

      # The circular buffer (do not modify).
      attr_reader :buffer

      # Where the next block will be written.
      attr_reader :write_offset

      # Where the last block written by #write starts.
      attr_reader :block_start

      # Creates a delay line holding +capacity+ samples of type +type+
      # (Numo::SFloat by default; complex input promotes it, see #prepare).
      def initialize(capacity = 1, type: Numo::SFloat)
        @buffer = type.zeros(MB::M.max(capacity.ceil, MARGIN + 2))
        @write_offset = 0
        @block_start = 0
      end

      # The NArray class of the buffer (and of what #read returns).
      def buffer_class
        @buffer.class
      end

      # The number of samples the buffer holds.
      def capacity
        @buffer.length
      end

      # Fills the buffer with +value+ (silence by default).
      def fill(value = 0)
        @buffer.fill(value)
        self
      end

      # Makes the buffer ready for a block of +length+ samples read back at
      # up to +max_delay+ samples: promotes it to complex if +type+ is a
      # complex NArray class, and grows it if needed.
      def prepare(length, max_delay, type = @buffer.class)
        promote(type)
        needed = length + max_delay.ceil + MARGIN
        grow(MB::M.max(needed, 2 * capacity)) if needed > capacity
        self
      end

      # Writes +data+ at #write_offset, remembering it as the block to read
      # back with #read.
      def write(data)
        @block_start = @write_offset
        MB::Sound::FastArithmetic.circular_write(@buffer, data, @write_offset) || MB::M.circular_write(@buffer, data, @write_offset)
        @write_offset = (@write_offset + data.length) % capacity
        self
      end

      # Returns a copy of +count+ samples already written, starting +delay+
      # (an Integer) samples before #write_offset (the next sample to be
      # written), oldest first: the samples a block of +count+ written next
      # would read at a constant delay of +delay+, before that block is
      # written.  +count+ may not exceed +delay+ (the samples must exist).
      # Used by GraphNode::Reverb to read its feedback at a fixed loop delay.
      #
      # +out+ is an optional NArray of the buffer's type and +count+ samples
      # to copy into instead of a new one (used when it fits; check the
      # result's identity).
      def past(count, delay, out: nil)
        raise ArgumentError, "Can't read #{count} samples from #{delay} samples ago" if count > delay
        raise ArgumentError, "Delay #{delay} is longer than the buffer (#{capacity})" if delay > capacity

        start = (@write_offset - delay) % capacity
        if out && out.length == count && MB::Sound::FastArithmetic.circular_read(@buffer, start, count, out)
          return out
        end

        stop = start + count
        return @buffer[start...stop].dup if stop <= capacity

        @buffer[start..].concatenate(@buffer[0...(stop - capacity)])
      end

      # Returns +count+ samples of the last block written by #write, delayed
      # by +delay+ samples: a Numeric for all samples, or an NArray with one
      # delay per sample.  Returns a new NArray of the buffer's type.
      #
      # +interpolation+ is one of INTERPOLATION's keys (this low-level
      # method defaults to :linear; delays default to DEFAULT_INTERPOLATION).
      # A Numeric delay reads at 1x (changing it between calls is a jump);
      # per-sample delays read at the speed their changes give.  For :sinc, +state+
      # should be an Array kept by each reader between calls (state[0] is
      # its previous delay, for the read speed).
      #
      # +out+ is an optional NArray to read into instead of a new one (used
      # if it has the buffer's type and +count+ samples; every sample is
      # overwritten), so a reader can reuse its buffer.
      def read(count, delay, interpolation: :linear, state: nil, out: nil)
        out = @buffer.class.zeros(count) unless out && out.class == @buffer.class && out.length == count && !out.frozen?
        MB::Sound::FastDelay.read(@buffer, out, @block_start, real_delay(delay), mode(interpolation), SINC_KERNEL, state)
      end

      # The Ruby version of #read.
      def read_ruby(count, delay, interpolation: :linear, state: nil)
        m = mode(interpolation)
        delay = real_delay(delay)

        case interpolation
        when :linear
          result = delay.is_a?(Numeric) ? read_constant(count, clamp(delay, m)) : read_varying(count, delay)
          if state
            last = delay.is_a?(Numeric) ? clamp(delay, m) : clamp(delay[count - 1], m)
            state[0] = last.to_f
          end
          result

        when :cubic
          read_cubic(count, delay, state)

        else
          out = @buffer.class.zeros(count)
          prev = state&.[](0)
          count.times do |i|
            d = clamp(delay.is_a?(Numeric) ? delay : delay[i], m)
            rate = prev && !delay.is_a?(Numeric) ? (1.0 - (d - prev)).abs : 1.0
            prev = d
            out[i] = interpolate(@block_start + i, d, m, rate)
          end
          state[0] = prev.to_f if state && prev
          out
        end
      end

      # Runs a delay network (GraphNode::DelayNetwork) for +count+ samples,
      # one sample at a time: +lines+ (real DelayLines, each prepared for
      # the block), +inputs+ (one SFloat or nil per line), +tap_lines+ (the
      # line index each tap reads), +delays+ (per tap: delays in samples, a
      # Numeric or an NArray per sample), +gains+ (per line, an Array with
      # a gain per tap: a Numeric, an NArray per sample, or nil for none).
      # Each sample writes every line's input, reads every tap (whole-sample
      # delays directly unless sinc, the sinc read speed from the tap's
      # previous delay, as #read), then adds each line's gains times the
      # taps to what it wrote, in double precision.
      #
      # +states+ is an Array of read-state Arrays (one per tap, see #read),
      # +outs+ an Array of SFloat buffers (one per tap, at least +count+
      # long) the taps are written into.  Returns +outs+.
      def self.network(lines, inputs, tap_lines, delays, gains, count, interpolation: :linear, states: nil, outs:)
        m = lines[0].send(:mode, interpolation)
        lines.each(&:begin_network_block)
        offsets = MB::Sound::FastDelay.network(
          lines.map(&:network_buffer), lines.map(&:write_offset_for_network), inputs, outs, tap_lines,
          delays.map { |d| lines[0].send(:real_delay, d) }, gains, m, SINC_KERNEL, states, count
        )
        lines.each_with_index { |l, j| l.end_network_block(offsets[j]) }
        outs
      end

      # The Ruby version of .network (the same arguments without +outs+;
      # returns new SFloat tap outputs).
      def self.network_ruby(lines, inputs, tap_lines, delays, gains, count, interpolation: :linear, states: nil)
        m = lines[0].send(:mode, interpolation)
        lines.each(&:begin_network_block)
        sinc = INTERPOLATION[:sinc]
        outs = tap_lines.map { Numo::SFloat.zeros(count) }
        prev = tap_lines.each_index.map { |t| states&.[](t)&.[](0) }
        ins = inputs.map { |b| b&.to_a }
        ds = delays.map { |d| d = lines[0].send(:real_delay, d); d.is_a?(Numo::NArray) ? d.to_a : d }
        gs = gains.map { |row| row.map { |g| g.is_a?(Numo::NArray) ? g.to_a : g } }
        offs = lines.map(&:write_offset_for_network)
        bufs = lines.map(&:network_buffer)

        count.times do |i|
          w = lines.each_with_index.map { |l, j|
            wj = (offs[j] + i) % l.capacity
            bufs[j][wj] = ins[j] ? ins[j][i] : 0.0
            wj
          }

          v = tap_lines.each_with_index.map { |j, t|
            l = lines[j]
            d = ds[t]
            d = l.send(:clamp, d.is_a?(Array) ? d[i] : d, m)
            rate = prev[t] && ds[t].is_a?(Array) ? (1.0 - (d - prev[t])).abs : 1.0
            prev[t] = d
            if d == d.floor && m != sinc
              bufs[j][(w[j] - d.to_i) % l.capacity]
            else
              l.send(:interpolate, w[j], d, m, rate)
            end
          }

          lines.each_index do |j|
            acc = bufs[j][w[j]]
            gs[j].each_with_index do |g, t|
              next if g.nil? || g == false
              acc += (g.is_a?(Array) ? g[i] : g.to_f) * v[t]
            end
            bufs[j][w[j]] = acc
          end

          v.each_with_index { |x, t| outs[t][i] = x }
        end

        prev.each_with_index { |p, t| states[t][0] = p.to_f if states && states[t] && !p.nil? }
        lines.each_with_index { |l, j| l.end_network_block((offs[j] + count) % l.capacity) }
        outs
      end

      # For .network: the buffer (raises for complex lines).
      def network_buffer
        raise ArgumentError, 'Delay networks run real (SFloat) lines only' if complex?
        @buffer
      end

      # For .network: the next sample's write offset.
      def write_offset_for_network
        @write_offset
      end

      # For .network: marks the block about to be written.
      def begin_network_block
        @block_start = @write_offset
      end

      # For .network: the write offset after the block.
      def end_network_block(offset)
        @write_offset = offset
      end

      # True if none of the last +window+ samples written has a magnitude of
      # at least +loud+ (a float bound, see QuietRun): the line holds only
      # silence that a read up to +window+ samples back could return.  For a
      # node's idle check (NodeTraits; asked only where a sleeper could fall
      # asleep), without allocating for real lines.
      def holds_quiet?(window, loud = QuietRun::QUIET_LOUD)
        n = window.ceil
        n = capacity if n > capacity
        return true if n <= 0

        start = (@write_offset - n) % capacity
        first = MB::M.min(n, capacity - start)
        quiet_range?(start, first, loud) && (first == n || quiet_range?(0, n - first, loud))
      end

      # Returns a copy of the buffer rotated so the oldest sample is first
      # and the newest is last.
      def unwrapped
        MB::M.rol(@buffer, @write_offset)
      end

      private

      # True if none of +n+ buffer samples from +start+ is at least +loud+.
      def quiet_range?(start, n, loud)
        i = MB::Sound::FastArithmetic.last_at_least(@buffer, start, n, loud)
        return i < 0 if i

        @buffer[start...(start + n)].abs.lt(loud).all?
      end

      # Returns the C number for an interpolation mode name.
      def mode(interpolation)
        INTERPOLATION.fetch(interpolation) {
          raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (use one of #{INTERPOLATION.keys.join(', ')})"
        }
      end

      # The number of samples older than floor(delay) that mode +m+ reads.
      def margin(m)
        case m
        when INTERPOLATION[:cubic] then 2
        when INTERPOLATION[:sinc] then (SINC_HALF * SINC_MAX_RATE).ceil + 1
        else 1
        end
      end

      # Converts the buffer to complex if +type+ is complex.
      def promote(type)
        if (type <= Numo::SComplex || type <= Numo::DComplex) && !complex?
          @buffer = Numo::SComplex.cast(@buffer)
        end
      end

      def complex?
        @buffer.is_a?(Numo::SComplex) || @buffer.is_a?(Numo::DComplex)
      end

      # Grows the buffer to +new_capacity+ samples, unwrapping the stored
      # audio oldest first so the newest sample ends just before the new
      # write offset (0), and moving #block_start to match.
      def grow(new_capacity)
        old_capacity = capacity
        extra = new_capacity - old_capacity
        block_age = (@block_start - @write_offset) % old_capacity

        new_buffer = @buffer.class.zeros(new_capacity)
        new_buffer[extra..] = unwrapped
        @buffer = new_buffer
        @block_start = extra + block_age
        @write_offset = 0
      end

      # Clamps a delay to 0..capacity - 1 - margin (so interpolation stays
      # inside the buffer), as a Float.
      def clamp(delay, m = INTERPOLATION[:linear])
        delay = delay.real if delay.respond_to?(:real)
        return 0.0 unless delay >= 0 # also NaN

        max = (capacity - 1 - margin(m)).to_f
        delay > max ? max : delay.to_f
      end

      # The sample at +delay+ (an Integer) before position +base+, never
      # newer than +base+, as a double-precision Float or Complex.
      def at(base, delay)
        @buffer[(base - (delay > 0 ? delay : 0)) % capacity]
      end

      # Interpolates at +d+ samples before position +base+ with mode +m+
      # (the same math as delay_interp_real/complex in C).
      def interpolate(base, d, m, rate)
        dmin = d.floor
        t = d - dmin

        case m
        when INTERPOLATION[:cubic]
          ym1 = at(base, dmin - 1)
          y0 = at(base, dmin)
          y1 = at(base, dmin + 1)
          y2 = at(base, dmin + 2)
          c0 = y0
          c1 = 0.5 * (y1 - ym1)
          c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
          c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)
          ((c3 * t + c2) * t + c1) * t + c0

        when INTERPOLATION[:sinc]
          return at(base, dmin) if t == 0 && rate <= 1 # the kernel is zero at other whole samples

          fc = rate > 1 ? 1.0 / (rate < SINC_MAX_RATE ? rate : SINC_MAX_RATE) : 1.0
          support = SINC_HALF / fc
          sum = 0.0
          wsum = 0.0
          ((d - support).ceil..(d + support).floor).each do |k|
            w = sinc_weight((k - d).abs * fc)
            sum += w * at(base, k)
            wsum += w
          end
          wsum != 0 ? sum / wsum : 0.0

        else
          a = at(base, dmin)
          b = at(base, dmin + 1)
          a * (1.0 - t) + b * t
        end
      end

      # The sinc kernel weight at +x+ samples from its center (see
      # sinc_weight in C).
      def sinc_weight(x)
        table = SINC_KERNEL[0]
        u = x * SINC_RESOLUTION
        j = u.to_i
        return 0.0 if j + 1 >= table.length

        f = u - j
        table[j] + (table[j + 1] - table[j]) * f
      end

      # Reads at one delay for every sample: one block copy for whole
      # samples, two blended copies otherwise.
      def read_constant(count, delay)
        dmin = delay.floor
        a = MB::M.circular_read(@buffer, (@block_start - dmin) % capacity, count)
        return a if delay == dmin

        delta = delay - dmin
        b = MB::M.circular_read(@buffer, (@block_start - dmin - 1) % capacity, count)
        @buffer.class.cast(double(a) * (1.0 - delta) + double(b) * delta)
      end

      # Reads at a delay per sample with linear interpolation (vectorized).
      def read_varying(count, delay)
        d = without_nan(Numo::DFloat.cast(delay)[0...count]).clip(0, capacity - 2)

        dmin = d.floor
        delta = d - dmin
        base = Numo::Int64.new(count).seq + @block_start
        dmin_i = Numo::Int64.cast(dmin)
        idx1 = (base - dmin_i) % capacity
        idx2 = (base - dmin_i - 1) % capacity

        @buffer.class.cast(double(@buffer[idx1]) * (1.0 - delta) + double(@buffer[idx2]) * delta)
      end

      # Reads with cubic interpolation (vectorized, the same math as C).
      def read_cubic(count, delay, state)
        max = capacity - 1 - margin(INTERPOLATION[:cubic])
        d = delay.is_a?(Numeric) ? Numo::DFloat.new(count).fill(clamp(delay, INTERPOLATION[:cubic])) : without_nan(Numo::DFloat.cast(delay)[0...count]).clip(0, max)

        dmin = d.floor
        t = d - dmin
        base = Numo::Int64.new(count).seq + @block_start
        di = Numo::Int64.cast(dmin)
        newer = di - 1
        newer[newer < 0] = 0

        ym1 = double(@buffer[(base - newer) % capacity])
        y0 = double(@buffer[(base - di) % capacity])
        y1 = double(@buffer[(base - di - 1) % capacity])
        y2 = double(@buffer[(base - di - 2) % capacity])
        c0 = y0
        c1 = 0.5 * (y1 - ym1)
        c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
        c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1)

        state[0] = d[-1] if state
        @buffer.class.cast(((c3 * t + c2) * t + c1) * t + c0)
      end

      # Returns a copy of +delays+ (a DFloat) with NaNs replaced by 0, as
      # the C code reads them.
      def without_nan(delays)
        nan = delays.isnan
        return delays unless nan.any?

        delays = delays.dup
        delays[nan] = 0
        delays
      end

      # Casts +data+ to DFloat, or DComplex for a complex buffer.
      def double(data)
        complex? ? Numo::DComplex.cast(data) : Numo::DFloat.cast(data)
      end

      # Returns the real part of complex delays (a delay is a time).
      def real_delay(delay)
        if delay.is_a?(Numo::SComplex) || delay.is_a?(Numo::DComplex) || delay.is_a?(Complex)
          delay.real
        else
          delay
        end
      end
    end
  end
end
