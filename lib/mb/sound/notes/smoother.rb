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
      #
      # Adaptive smoothing (+length+ a Range of times, e.g. 5.ms..200.ms;
      # `smooth: :adaptive` on Notes nodes gives Notes::ADAPTIVE_SMOOTHING):
      # each value step glides linearly from the current output to the new
      # value over the time since the previous step, clamped to the Range,
      # expecting the next step after about the same delay (the user's
      # scroll-bar smoothing).  A slow 7-bit wheel or knob, stepping every
      # 30-150 ms, becomes a continuous line instead of a staircase (each
      # ramp ends as the next step arrives), and fast streams glide over
      # the Range's minimum.  The output lags by one step interval (at most
      # the maximum); the first step after a rest takes the maximum.  Kernel
      # FastControl.adaptive (mb_smooth.h), exact mirror .adaptive_ruby.
      #
      # Curve smoothing (+curve:+, anything MB::Sound::Curve.from takes:
      # :elastic, :bounce, :smoothstep, a Curve, a Proc): a linear filter
      # whose step response is the curve over +length+ (GraphNode#smooth's
      # `curve:`, e.g. an elastic knob), so a single step follows the
      # curve exactly and a stream of steps (a turned knob, an already
      # smooth signal) sums their curves, the way a spring follows a
      # dragged end.  It sums the steps still moving each sample, starting
      # one at most every `length / CURVE_SLOTS` samples (later changes
      # wait for it: at most CURVE_SLOTS steps move at once, so a moving
      # input costs about CURVE_SLOTS table reads a sample, a still one
      # none).  Kernel FastControl.curve (mb_smooth.h), exact mirror
      # .curve_ruby; the table holds the curve at each of the length's
      # samples (Curve#map, as the old Filter::Smoothstep drew them).
      #
      # A smoother whose length is nil or false passes its input through
      # unchanged (a kernel of one sample); Notes nodes that follow the
      # global defaults keep one so the defaults can change live (see
      # Notes.control_smoothing and #length=).
      class Smoother
        # The adaptive kernel's state length (see .adaptive_ruby); the fixed
        # kernel's state has 7 values.
        ADAPTIVE_STATE = 8

        # The curve kernel's state length (see .curve_ruby).
        CURVE_STATE = 9

        # The most curve steps moving at once (see the class description).
        CURVE_SLOTS = 64

        # The step-response curve (an MB::Sound::Curve), or nil for the
        # fixed (B-spline) or adaptive kernel.
        attr_reader :curve

        # The smoothing time as given (seconds or a Length; a Range for
        # adaptive smoothing; nil when passing the input through).
        attr_reader :length

        # The kernel's length in samples at the current rate (a step takes
        # this many samples, minus one, to complete); for adaptive
        # smoothing, the longest ramp.
        attr_reader :kernel_samples

        # Smooths over +length+ (seconds, or anything Length.samples takes;
        # a Range of them for adaptive smoothing; nil or false to pass the
        # input through) at +sample_rate+, with the B-spline kernel or (with
        # +curve:+) the curve kernel (see the class description).
        def initialize(length, sample_rate:, curve: nil)
          @length = length || nil
          @curve = curve.nil? ? nil : MB::Sound::Curve.from(curve)
          raise ArgumentError, 'Curve smoothing needs a length (not a Range or nil)' if @curve && (@length.nil? || adaptive?)

          @state = nil
          @out = nil
          self.sample_rate = sample_rate
        end

        # True for adaptive smoothing (a Range length).
        def adaptive?
          @length.is_a?(Range)
        end

        # True for curve smoothing (see the class description).
        def curve?
          !@curve.nil?
        end

        # True if the output is the input (a nil or false length).
        def off?
          @length.nil?
        end

        # Changes the smoothing (see #initialize) while running: a glide in
        # progress continues from the current output to the current input
        # value with the new kernel (no jump), so a live change of the
        # global defaults (Notes.control_smoothing) doesn't click.
        def length=(length)
          length ||= nil
          return if length == @length

          if @state
            y = current_output
            last = @state[1]
          end
          raise ArgumentError, 'Curve smoothing needs a length (not a Range or nil)' if @curve && (length.nil? || length.is_a?(Range))

          @length = length
          @state = nil
          self.sample_rate = @rate
          return unless y

          settle_at(last)
          resume_at(y)
        end

        # Changes the sample rate, recomputing the kernel's length and
        # settling at the current value.
        def sample_rate=(rate)
          @rate = rate.to_f
          if curve?
            n = [Length.samples(@length, sample_rate: @rate).round, 1].max
            @kernel_samples = n
            @settle = 0
            @curve_gap = (n.to_f / CURVE_SLOTS).ceil.to_f
            @ring1 = Numo::DFloat.zeros(2 * CURVE_SLOTS)
            @ring2 = @curve.map((Numo::DFloat.new(n).seq + 1) / n)
            @ring2 = Numo::DFloat.cast(@ring2) unless @ring2.is_a?(Numo::DFloat)
          elsif adaptive?
            lo = [Length.samples(@length.begin, sample_rate: @rate).round, 1].max
            hi = [Length.samples(@length.end, sample_rate: @rate).round, lo].max
            @adaptive_range = [lo.to_f, hi.to_f]
            @kernel_samples = hi
            @settle = 0
            @ring1 = Numo::DFloat.zeros(1)
            @ring2 = Numo::DFloat.zeros(1)
          else
            if @length.nil?
              n1 = n2 = 1
            else
              n = Length.samples(@length, sample_rate: @rate).round
              n = 4 if n < 4
              n1 = n / 2
              n2 = n - n1
            end
            @adaptive_range = nil
            @kernel_samples = n1 + n2 - 1
            @settle = n1 + n2 - 2
            @ring1 = Numo::DFloat.zeros(n1)
            @ring2 = Numo::DFloat.zeros(n2)
          end
          settle_at(@state[1]) if @state
        end

        # The sample rate the kernel was computed for.
        def sample_rate
          @rate
        end

        # True if the output equals the input (nothing is moving).
        def settled?
          return true if @state.nil?
          return @state[6] == 0 && @state[2] == @state[1] if curve?

          adaptive? ? @state[5] >= @state[4] : @state[6] >= @settle
        end

        # Returns the smoothed +buf+ (an SFloat): +buf+ itself while settled
        # and +buf+ is +constant+ (its Float value, or nil if unknown) at the
        # held value, else a reused buffer.  +jumps+ lists sample offsets
        # (sorted) where the output jumps straight to the input instead.
        def process(buf, constant = nil, jumps = nil)
          count = buf.length
          settle_at(constant || buf[0]) if @state.nil?
          st = @state
          if constant && constant == st[1] && settled? && (jumps.nil? || jumps.empty?)
            # The adaptive kernel counts the samples since the last step, the
            # curve kernel since its newest step (up to its gap)
            st[3] = [st[3] + count, st[7]].min if st.length == ADAPTIVE_STATE
            st[3] = [st[3] + count, st[4]].min if st.length == CURVE_STATE
            return buf
          end

          buf = Numo::SFloat.cast(buf) unless buf.is_a?(Numo::SFloat) && buf.contiguous?
          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          self.class.run(buf, @out, 0, count, st, @ring1, @ring2, jumps)
          @out
        end

        # Like #process (no constant shortcut), jumping to the input at
        # every nonzero sample of +reset+ (GraphNode#smooth's reset:), in C
        # (FastControl.reset_run); the same as #process with the reset's
        # nonzero offsets as jumps (the Ruby mirror, .reset_run_ruby, is
        # that).
        def process_reset(buf, reset)
          count = buf.length
          settle_at(buf[0]) if @state.nil?
          buf = Numo::SFloat.cast(buf) unless buf.is_a?(Numo::SFloat) && buf.contiguous?
          reset = reset[0...count] if reset.length > count
          reset = Numo::SFloat.cast(reset) unless reset.is_a?(Numo::SFloat) && reset.contiguous?
          @out = Numo::SFloat.zeros(count) if @out.nil? || @out.length != count
          return @out if count == 0

          if reset.length < count
            self.class.run(buf, @out, 0, count, @state, @ring1, @ring2, reset.ne(0).where.to_a)
          else
            Kernels.smooth_reset_run(buf, @out, @state, @ring1, @ring2, reset)
          end
          @out
        end

        # Smooths x[from...to] into out[from...to] with +state+ and the rings
        # (the fixed kernel's, or the adaptive one's for an ADAPTIVE_STATE
        # state), jumping to the input at the offsets in +jumps+ (sorted;
        # others ignored), through the kernels (FastControl, or the Ruby
        # mirrors; see MB::Sound::Kernels).  Plans (Plan::Op::Smooth) run the
        # same steps.
        def self.run(x, out, from, to, state, ring1, ring2, jumps)
          start = from
          jumps&.each do |j|
            next if j < start || j >= to
            segment(x, out, start, j, state, ring1, ring2) if j > start
            jump(state, x[j], ring1, ring2)
            start = j
          end
          segment(x, out, start, to, state, ring1, ring2) if start < to
          out
        end

        # Runs one kernel over x[from...to] (see .run).
        def self.segment(x, out, from, to, state, ring1, ring2)
          if state.length == ADAPTIVE_STATE
            Kernels.smooth_adaptive(x, out, from, to, state)
          elsif state.length == CURVE_STATE
            Kernels.smooth_curve(x, out, from, to, state, ring1, ring2)
          else
            Kernels.smooth(x, out, from, to, state, ring1, ring2)
          end
        end

        # The Ruby mirror of FastControl.reset_run: .run with a jump at every
        # nonzero sample of +reset+.
        def self.reset_run_ruby(x, out, state, ring1, ring2, reset)
          run(x, out, 0, x.length, state, ring1, ring2, reset[0...x.length].ne(0).where.to_a)
        end

        # Makes the output jump to +value+ (the input at a jump offset):
        # held there with nothing moving.
        def self.jump(state, value, ring1, ring2)
          if state.length == ADAPTIVE_STATE
            state[0] = value
            state[1] = value
            state[2] = value
            state[3] = 0.0
            state[5] = state[4]
          elsif state.length == CURVE_STATE
            state[0] = value
            state[1] = value
            state[2] = value
            state[3] = state[4]
            state[6] = 0.0
            state[7] = 0.0
          else
            state[1] = value
            state[6] = (ring1.length + ring2.length - 2).to_f
          end
        end

        # The Ruby mirror of FastControl.adaptive (mb_smooth.h): adaptive
        # smoothing (see the class description) of x[from...to] into
        # out[from...to] with +state+ [output, last input, ramp start,
        # samples since the last step, ramp length, ramp position, shortest
        # ramp, longest ramp] (samples as Floats).
        def self.adaptive_ruby(x, out, from, to, state)
          y, last, start, since, t, pos, lo, hi = state.to_a

          (from...to).each do |i|
            v = x[i]
            since += 1.0 if since < hi
            if v != last
              t = since < lo ? lo : since
              start = y
              last = v
              pos = 0.0
              since = 0.0
            end

            if pos < t
              pos += 1.0
              y = pos >= t ? v : start + (v - start) * (pos / t)
            else
              y = v
            end
            out[i] = y
          end

          state[0...8] = [y, last, start, since, t, pos, lo, hi]
          out
        end

        # The Ruby mirror of FastControl.curve (mb_curve_smooth_run in
        # mb_smooth.h): curve smoothing (see the class description) of
        # x[from...to] into out[from...to] with +state+ [base, last input,
        # newest target, samples since the newest step, gap, length, count,
        # head, slot capacity], +slots+ ([age, target] pairs), and +table+
        # (the curve at (k + 1) / length).
        def self.curve_ruby(x, out, from, to, state, slots, table)
          base, last, newest, since, gap, n, count, head, cap = state.to_a
          n = n.to_i
          count = count.to_i
          head = head.to_i
          cap = cap.to_i
          raise ArgumentError, 'Bad curve smoother state' if n < 1 || n > table.length || cap < 1 || cap * 2 > slots.length || count > cap || head >= cap

          (from...to).each do |i|
            v = x[i]
            last = v

            while count > 0 && slots[2 * head] >= n
              base = slots[2 * head + 1]
              head = head + 1 == cap ? 0 : head + 1
              count -= 1
            end

            if v != newest && since >= gap
              if count == cap
                base = slots[2 * head + 1]
                head = head + 1 == cap ? 0 : head + 1
                count -= 1
              end
              j = head + count
              j -= cap if j >= cap
              slots[2 * j] = 0.0
              slots[2 * j + 1] = v
              count += 1
              newest = v
              since = 0.0
            end

            y = base
            prev = base
            j = head
            k = 0
            while k < count
              age = slots[2 * j]
              target = slots[2 * j + 1]
              y += (target - prev) * table[age.to_i]
              prev = target
              slots[2 * j] = age + 1.0
              j = j + 1 == cap ? 0 : j + 1
              k += 1
            end

            since += 1.0 if since < gap
            out[i] = y
          end

          state[0] = base
          state[1] = last
          state[2] = newest
          state[3] = since
          state[6] = count.to_f
          state[7] = head.to_f
          out
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

        # For plans (Plan::Op::Smooth): true before the first block.
        def plan_unstarted?
          @state.nil?
        end

        # For plans: starts held at +value+ (the first block's first input,
        # as #process does).
        def plan_start(value)
          settle_at(value)
        end

        # For plans: the filter's state Arrays [state, ring1, ring2]
        # (DFloats read and written by the executor; the state's length
        # picks the kernel, see .run).
        def plan_arrays
          [@state, @ring1, @ring2]
        end

        # For check mode: the length and state as plain values (a curve's
        # table never changes, so it isn't kept).
        def plan_snapshot
          [@length, @state&.to_a, @ring1.to_a, curve? ? nil : @ring2.to_a]
        end

        # For check mode: restores #plan_snapshot.
        def plan_restore(snapshot)
          length, state, ring1, ring2 = snapshot
          unless length == @length
            @length = length
            @state = nil
            self.sample_rate = @rate
          end

          if state.nil?
            @state = nil
            return
          end

          @state = Numo::DFloat.cast(state)
          @ring1 = Numo::DFloat.cast(ring1)
          @ring2 = Numo::DFloat.cast(ring2) if ring2
        end

        private

        # The last output value (the held value when settled).
        def current_output
          st = @state
          if st.length == ADAPTIVE_STATE
            st[0]
          elsif st.length == CURVE_STATE
            y = st[0]
            prev = st[0]
            head = st[7].to_i
            st[6].to_i.times do |k|
              j = (head + k) % CURVE_SLOTS
              age = [@ring1[2 * j].to_i, @kernel_samples - 1].min
              y += (@ring1[2 * j + 1] - prev) * @ring2[age]
              prev = @ring1[2 * j + 1]
            end
            y
          elsif st[6] >= (@ring1.length + @ring2.length - 2)
            st[1]
          else
            st[0] + st[3] / @ring2.length
          end
        end

        # Holds +value+ with nothing moving.
        def settle_at(value)
          if curve?
            @state = Numo::DFloat[value, value, value, @curve_gap, @curve_gap, @kernel_samples, 0, 0, CURVE_SLOTS]
            @ring1.fill(0)
          elsif adaptive?
            lo, hi = @adaptive_range
            @state = Numo::DFloat[value, value, value, hi, lo, lo, lo, hi]
          else
            @state = Numo::DFloat[value, value, 0, 0, 0, 0, @settle]
            @ring1.fill(0)
            @ring2.fill(0)
          end
        end

        # Continues from output +y+ (after a kernel change) toward the held
        # input value: a glide of the new kernel's (shortest) length, or
        # settled if already there.
        def resume_at(y)
          last = @state[1]
          return if y == last

          if curve?
            # Held at y; the next sample starts a step to the input
            @state = Numo::DFloat[y, y, y, @curve_gap, @curve_gap, @kernel_samples, 0, 0, CURVE_SLOTS]
            @ring1.fill(0)
          elsif adaptive?
            lo, hi = @adaptive_range
            @state = Numo::DFloat[y, last, y, 0, lo, 0, lo, hi]
          else
            @state = Numo::DFloat[y, last, 0, 0, 0, 0, 0]
            @ring1.fill(0)
            @ring2.fill(0)
          end
        end
      end

      Kernels.register :smooth, c: FastControl.method(:smooth), ruby: Smoother.method(:smooth_ruby)
      Kernels.register :smooth_adaptive, c: FastControl.method(:adaptive), ruby: Smoother.method(:adaptive_ruby)
      Kernels.register :smooth_curve, c: FastControl.method(:curve), ruby: Smoother.method(:curve_ruby)
      Kernels.register :smooth_reset_run, c: FastControl.method(:reset_run), ruby: Smoother.method(:reset_run_ruby)
    end
  end
end
