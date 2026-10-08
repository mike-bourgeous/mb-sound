module MB
  module Sound
    class Notes
      # Smooths the stepped output of a controller node (CCs, pressure,
      # pitch bend; see Notes#cc and Notes.control_smoothing) so MIDI's
      # value steps don't zipper: a linear FIR filter whose kernel is a
      # triangle (two cascaded moving averages of half the time each), so
      # each step becomes an S-shaped quadratic B-spline transition of
      # +length+ (continuous slope; on 7-bit pressure steps every 4 ms, 5
      # and 10 ms leave the zipper's energy above 2 kHz about 60 and 70 dB
      # lower), and a stream of steps
      # becomes their smooth interpolation.  The output reaches each new
      # value exactly after +length+ (no endless one-pole tail), and with
      # nothing moving the input buffer passes through unchanged (the frozen
      # constant buffers of Notes fast paths stay allocation-free).  Delay:
      # half the length (the kernel is symmetric).
      #
      # The filter runs in C (FastControl.smooth, exact Ruby mirror
      # .smooth_ruby; ~1 us per moving 128-sample buffer) as running sums of
      # the deviation from the last held value in double precision; once
      # the input has held for the kernel's length the output is the input
      # exactly and the sums restart, so settled stretches are exact and
      # rounding doesn't carry across them.  Jumps (see #process) restart
      # the filter at a new value, for values that must change at once (a
      # new note's poly pressure, content jumps).
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
          @state = nil
          self.sample_rate = sample_rate
        end

        # Changes the sample rate, recomputing the kernel's length and
        # settling at the current value.
        def sample_rate=(rate)
          @rate = rate.to_f
          n = Length.samples(@length, sample_rate: @rate).round
          n = 4 if n < 4
          n1 = n / 2
          n2 = n - n1
          @kernel_samples = n1 + n2 - 1
          @settle = n1 + n2 - 2
          @ring1 = Numo::DFloat.zeros(n1)
          @ring2 = Numo::DFloat.zeros(n2)
          settle_at(@state[1]) if @state
        end

        # The sample rate the kernel was computed for.
        def sample_rate
          @rate
        end

        # True if the output equals the input (nothing is moving).
        def settled?
          @state.nil? || @state[6] >= @settle
        end

        # Returns the smoothed +buf+ (an SFloat): +buf+ itself while settled
        # and +buf+ is +constant+ (its Float value, or nil if unknown) at the
        # held value, else a reused buffer.  +jumps+ lists sample offsets
        # (sorted) where the output jumps straight to the input instead.
        def process(buf, constant = nil, jumps = nil)
          count = buf.length
          settle_at(constant || buf[0]) if @state.nil?
          st = @state
          return buf if constant && st[6] >= @settle && constant == st[1] && (jumps.nil? || jumps.empty?)

          buf = Numo::SFloat.cast(buf) unless buf.is_a?(Numo::SFloat) && buf.contiguous?
          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          start = 0
          jumps&.each do |j|
            next if j < start || j >= count
            FastControl.smooth(buf, @out, start, j, st, @ring1, @ring2) if j > start
            st[1] = buf[j]
            st[6] = @settle
            start = j
          end
          FastControl.smooth(buf, @out, start, count, st, @ring1, @ring2) if start < count

          @out
        end

        # The Ruby mirror of FastControl.smooth (see
        # ext/mb/sound/fast_control/fast_control.c): smooths x[from...to]
        # into out[from...to] with +state+ [ref, last, sum1, sum2, p1, p2,
        # since] and the rings' lengths as the two moving averages, giving
        # exactly the same samples.
        def self.smooth_ruby(x, out, from, to, state, ring1, ring2)
          n1 = ring1.length
          n2 = ring2.length
          settle = (n1 + n2 - 2).to_f
          ref, last, s1, s2, p1, p2, since = state.to_a
          p1 = p1.to_i
          p2 = p2.to_i

          (from...to).each do |i|
            v = x[i]

            if v != last
              if since >= settle
                ref = last
                ring1.fill(0)
                ring2.fill(0)
                s1 = 0.0
                s2 = 0.0
              end
              since = 0.0
              last = v
            elsif since < settle
              since += 1.0
            end

            if since >= settle
              out[i] = v
            else
              d = v - ref
              s1 += d - ring1[p1]
              ring1[p1] = d
              p1 += 1
              p1 = 0 if p1 == n1

              s = s1 / n1.to_f
              s2 += s - ring2[p2]
              ring2[p2] = s
              p2 += 1
              p2 = 0 if p2 == n2

              out[i] = ref + s2 / n2.to_f
            end
          end

          state[0...7] = [ref, last, s1, s2, p1.to_f, p2.to_f, since]
          out
        end

        private

        # Holds +value+ with nothing moving.
        def settle_at(value)
          @state = Numo::DFloat[value, value, 0, 0, 0, 0, @settle]
          @ring1.fill(0)
          @ring2.fill(0)
        end
      end
    end
  end
end
