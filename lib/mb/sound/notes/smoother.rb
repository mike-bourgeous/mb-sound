module MB
  module Sound
    class Notes
      # Smooths the stepped output of a controller node (CCs, pressure,
      # pitch bend; see Notes#cc and Notes.control_smoothing) so MIDI's
      # value steps don't zipper: a linear FIR filter whose kernel is a
      # triangle (two cascaded moving averages of half the time each), so
      # each step becomes an S-shaped quadratic B-spline transition of
      # +length+ (continuous slope; 5 ms or more of 7-bit steps leave the
      # zipper's energy above 2 kHz 55-70 dB lower), and a stream of steps
      # becomes their smooth interpolation.  The output reaches each new
      # value exactly after +length+ (no endless one-pole tail), and with
      # nothing moving the input buffer passes through unchanged (the frozen
      # constant buffers of Notes fast paths stay allocation-free).  Delay:
      # half the length (the kernel is symmetric).
      #
      # The filter is computed from the input's recent history for each
      # buffer (cumulative sums of the deviation from the buffer's final
      # value in double precision), so settled stretches are exact and
      # nothing drifts.  Jumps (see #process) restart the filter at a new
      # value, for values that must change at once (a new note's poly
      # pressure, content jumps).
      class Smoother
        # The smoothing time as given (seconds or a Length).
        attr_reader :length

        # The kernel's length in samples at the current rate (a step takes
        # this many samples, minus one, to complete).
        attr_reader :kernel_samples

        # Smooths over +length+ (seconds, or anything Length.samples takes)
        # at +sample_rate+.
        def initialize(length, sample_rate:)
          @length = length
          @value = nil
          self.sample_rate = sample_rate
        end

        # Changes the sample rate, recomputing the kernel's length and
        # settling at the current value.
        def sample_rate=(rate)
          @rate = rate.to_f
          n = Length.samples(@length, sample_rate: @rate).round
          n = 4 if n < 4
          @n1 = n / 2
          @n2 = n - @n1
          @kernel_samples = @n1 + @n2 - 1
          @history_samples = @n1 + @n2 - 2
          @hist = nil
          @settle = 0
        end

        # The sample rate the kernel was computed for.
        def sample_rate
          @rate
        end

        # True if the output equals the input (nothing is moving).
        def settled?
          @settle == 0
        end

        # Returns the smoothed +buf+: +buf+ itself while settled and +buf+
        # is +constant+ (its Float value, or nil if unknown) at the held
        # value, else a reused buffer.  +jumps+ lists sample offsets (sorted)
        # where the output jumps straight to the input instead.
        def process(buf, constant = nil, jumps = nil)
          count = buf.length
          @value = (constant || buf[0]) if @value.nil?
          return buf if @settle == 0 && constant && constant == @value && (jumps.nil? || jumps.empty?)

          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          start = 0
          jumps&.each do |j|
            next if j < start || j >= count
            segment(buf, start, j) if j > start
            @value = buf[j]
            @hist = nil
            @settle = 0
            start = j
          end
          segment(buf, start, count) if start < count

          @out
        end

        private

        # Smooths buf[from...to] into @out[from...to].
        def segment(buf, from, to)
          n = to - from
          x = buf[from...to]
          last = x[-1]

          # Where the input's final constant run starts (0 if it starts at or
          # before the segment's start)
          change = 0
          if n > 1
            idx = x[1..].ne(x[0...-1]).where
            change = idx[-1] + 1 if idx.length > 0
          end
          moved = change > 0 || x[0] != @value

          if @settle == 0 && !moved
            # Settled and unchanged: the output is the input
            @out[from...to] = x
          else
            hist = @hist || Numo::DFloat.new(@history_samples).fill(@value)
            ext = hist.concatenate(Numo::DFloat.cast(x))
            y = boxcar(boxcar(ext - last, @n1), @n2)
            @out[from...to] = y + last
            @hist = ext[-@history_samples..].dup
          end

          # Samples after this segment until the output is exact again
          @settle = moved ? [change + @kernel_samples - 1 - n, 0].max : [@settle - n, 0].max
          @value = last
          @hist = nil if @settle == 0
        end

        # Moving average of +n+ samples over +x+ (the first n - 1 outputs
        # are dropped, so the result is n - 1 shorter).
        def boxcar(x, n)
          return x if n <= 1
          c = x.cumsum
          head = c[n - 1].to_f
          out = c[n..] - c[0...-n]
          out = Numo::DFloat[head].concatenate(out)
          out * (1.0 / n)
        end
      end
    end
  end
end
