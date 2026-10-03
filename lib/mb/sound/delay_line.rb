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
    # #read and #feedback run in C (MB::Sound::FastDelay.read and .feedback,
    # in the fast_delay extension); #read_ruby and #feedback_ruby are the same math in
    # Ruby, and specs check that both give exactly the same values.
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
        MB::M.circular_write(@buffer, data, @write_offset)
        @write_offset = (@write_offset + data.length) % capacity
        self
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
      def read(count, delay, interpolation: :linear, state: nil)
        MB::Sound::FastDelay.read(@buffer, @buffer.class.zeros(count), @block_start, real_delay(delay), mode(interpolation), SINC_KERNEL, state)
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

      # Runs +data+ through a feedback loop one sample at a time: writes
      # each input sample plus +feedback+ times the delayed output, and
      # returns the delayed output (without the input).  The +delay+ is a
      # Numeric or an NArray with one delay per sample, as for #read, and
      # +feedback+ is a Numeric or an NArray with one gain per sample.
      def feedback(data, delay, feedback, interpolation: :linear, state: nil)
        @block_start = @write_offset
        out = @buffer.class.zeros(data.length)
        @write_offset = MB::Sound::FastDelay.feedback(@buffer, @write_offset, data, out, real_delay(delay), feedback, mode(interpolation), SINC_KERNEL, state)
        out
      end

      # The Ruby version of #feedback.
      def feedback_ruby(data, delay, feedback, interpolation: :linear, state: nil)
        m = mode(interpolation)
        delay = real_delay(delay)
        @block_start = @write_offset
        cap = capacity
        buf = @buffer
        out = buf.class.zeros(data.length)
        prev = state&.[](0)

        data.length.times do |i|
          d = clamp(delay.is_a?(Numeric) ? delay : delay[i], m)
          rate = prev && !delay.is_a?(Numeric) ? (1.0 - (d - prev)).abs : 1.0
          prev = d

          w = (@write_offset + i) % cap
          buf[w] = data[i]

          if d == d.floor && m != INTERPOLATION[:sinc]
            v = buf[(w - d.to_i) % cap]
          else
            v = interpolate(w, d, m, rate)
          end

          buf[w] += (feedback.is_a?(Numeric) ? feedback : feedback[i]) * v
          out[i] = v
        end

        state[0] = prev.to_f if state && prev
        @write_offset = (@write_offset + data.length) % cap
        out
      end

      # Returns a copy of the buffer rotated so the oldest sample is first
      # and the newest is last.
      def unwrapped
        MB::M.rol(@buffer, @write_offset)
      end

      private

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
        return 0.0 if delay < 0

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
        d = Numo::DFloat.cast(delay)[0...count].clip(0, capacity - 2)

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
        d = delay.is_a?(Numeric) ? Numo::DFloat.new(count).fill(clamp(delay, INTERPOLATION[:cubic])) : Numo::DFloat.cast(delay)[0...count].clip(0, max)

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
