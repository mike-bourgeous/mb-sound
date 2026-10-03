module MB
  module Sound
    # The circular buffer behind every delay (Filter::Delay and
    # GraphNode::MultitapDelay): write a block of input, then read it back
    # at a constant delay or a delay per sample (fractional delays use
    # linear interpolation), or run input through a feedback loop one
    # sample at a time.
    #
    # Delays are in samples, counted back from each output sample's own
    # input sample: after writing a block, output sample i of a read at
    # delay d is the input from d samples before input sample i (so a delay
    # of 0 returns the block itself).  Delays are clamped to 0 and to the
    # buffer's capacity.
    #
    # #read and #feedback run in C (MB::FastSound.delay_read and
    # .delay_feedback); #read_ruby and #feedback_ruby are the same math in
    # Ruby, and specs check that both give exactly the same values.
    #
    # The buffer grows when a block plus the longest delay doesn't fit
    # (see #prepare), keeping the stored audio: growing unwraps it oldest
    # first, so delays read the same samples afterwards.  Growing allocates
    # memory, so size the buffer for the longest delay up front for live
    # use.
    class DelayLine
      # The circular buffer (do not modify).
      attr_reader :buffer

      # Where the next block will be written.
      attr_reader :write_offset

      # Where the last block written by #write starts.
      attr_reader :block_start

      # Creates a delay line holding +capacity+ samples of type +type+
      # (Numo::SFloat by default; complex input promotes it, see #prepare).
      def initialize(capacity = 1, type: Numo::SFloat)
        @buffer = type.zeros(MB::M.max(capacity.ceil, 1))
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
        needed = length + max_delay.ceil + 2
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
      def read(count, delay)
        MB::FastSound.delay_read(@buffer, @buffer.class.zeros(count), @block_start, real_delay(delay))
      end

      # The Ruby version of #read.
      def read_ruby(count, delay)
        if delay.is_a?(Numeric)
          read_constant(count, clamp(delay))
        else
          read_varying(count, delay)
        end
      end

      # Runs +data+ through a feedback loop one sample at a time: writes
      # each input sample plus +feedback+ times the delayed output, and
      # returns the delayed output (without the input).  The +delay+ is a
      # Numeric or an NArray with one delay per sample, as for #read, and
      # +feedback+ is a Numeric or an NArray with one gain per sample.
      def feedback(data, delay, feedback)
        @block_start = @write_offset
        out = @buffer.class.zeros(data.length)
        @write_offset = MB::FastSound.delay_feedback(@buffer, @write_offset, data, out, real_delay(delay), feedback)
        out
      end

      # The Ruby version of #feedback.
      def feedback_ruby(data, delay, feedback)
        @block_start = @write_offset
        cap = capacity
        buf = @buffer
        out = buf.class.zeros(data.length)
        constant = delay.is_a?(Numeric)
        d = clamp(delay) if constant

        data.length.times do |i|
          d = clamp(delay[i].real) unless constant
          w = (@write_offset + i) % cap
          buf[w] = data[i]

          dmin = d.floor
          v = buf[(w - dmin) % cap]
          if d != dmin
            delta = d - dmin
            v = v * (1.0 - delta) + buf[(w - dmin - 1) % cap] * delta
          end

          buf[w] += (feedback.is_a?(Numeric) ? feedback : feedback[i]) * v
          out[i] = v
        end

        @write_offset = (@write_offset + data.length) % cap
        out
      end

      # Returns a copy of the buffer rotated so the oldest sample is first
      # and the newest is last.
      def unwrapped
        MB::M.rol(@buffer, @write_offset)
      end

      private

      # Converts the buffer to complex if +type+ is complex.
      def promote(type)
        if (type <= Numo::SComplex || type <= Numo::DComplex) && !(@buffer.is_a?(Numo::SComplex) || @buffer.is_a?(Numo::DComplex))
          @buffer = Numo::SComplex.cast(@buffer)
        end
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

      # Clamps a delay to 0..capacity - 2 (so interpolation stays inside
      # the buffer).
      def clamp(delay)
        delay = delay.real if delay.respond_to?(:real)
        return 0 if delay < 0

        max = capacity - 2
        delay > max ? max : delay
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
        d = Numo::DFloat.cast(delay.respond_to?(:real) && !delay.is_a?(Numo::DFloat) && !delay.is_a?(Numo::SFloat) ? delay.real : delay)[0...count]
        d = d.clip(0, capacity - 2)

        dmin = d.floor
        delta = d - dmin
        base = Numo::Int64.new(count).seq + @block_start
        dmin_i = Numo::Int64.cast(dmin)
        idx1 = (base - dmin_i) % capacity
        idx2 = (base - dmin_i - 1) % capacity

        @buffer.class.cast(double(@buffer[idx1]) * (1.0 - delta) + double(@buffer[idx2]) * delta)
      end

      # Casts +data+ to DFloat, or DComplex for a complex buffer.
      def double(data)
        complex = @buffer.is_a?(Numo::SComplex) || @buffer.is_a?(Numo::DComplex)
        complex ? Numo::DComplex.cast(data) : Numo::DFloat.cast(data)
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
