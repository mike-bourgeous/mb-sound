module MB
  module Sound
    module Analysis
      # The pitch over the first WINDOW (300 ms), cycle by cycle: the
      # times between upward zero crossings of the sound low-passed above
      # its dominant partial.  PitchContour's 40 ms YIN windows every
      # 10 ms blur a kick's drop (most of a 909's sweep is over in 30 ms);
      # counting cycles follows it as fast as the pitch moves.
      #
      # It works for sounds whose dominant partial is the fundamental and
      # stands well over the rest (kicks, toms, sine and triangle basses,
      # filtered tones): the low-pass cutoff is 1.5 times the strongest
      # spectral peak of the attack (or of the body, if higher), and the
      # result is dropped (nil from PitchEnvelope.of) when fewer than
      # MIN_CYCLES cycles are found, the periods change unevenly (median
      # second difference of log2 periods over MAX_JITTER), or the cycles disagree with
      # PitchContour's body pitch by more than a semitone where both read
      # it.  Pitch envelopes are the toolkit's known weak spot (the
      # maintainer heard round 3's kick fits' pitch envelopes as wrong on
      # every 909 item): look at the first-50-ms image too.
      #
      #     pe = Analysis::PitchEnvelope.of(kick)
      #     pe.at(0.01)       # => Hz 10 ms after the onset
      #     pe.half_time      # => seconds to cover half the drop (in cents)
      #     puts pe           # "pitch envelope falls from 236 Hz to 61 Hz: ..."
      class PitchEnvelope
        WINDOW = 0.3
        MIN_CYCLES = 6

        # The median second difference of the cycles' log2 periods above
        # which the crossings are noise, not a pitch (a sweep's periods
        # change by a steady ratio, so its second differences are small).
        MAX_JITTER = 0.08

        # Times (seconds from the onset, cycle centers) and frequencies (Hz)
        # of each cycle.
        attr_reader :times, :hz

        # :falling, :rising, or :steady (less than a semitone between the
        # first and last three cycles).
        attr_reader :direction

        # The PitchEnvelope of +sound+ (anything Signal.from takes), or nil
        # if its cycles can't be followed (see the class description).
        def self.of(sound)
          sig = Signal.from(sound)
          sig.memo(:pitch_envelope) { new(sig) }.then { |pe| pe.valid? ? pe : nil }
        end

        def initialize(sound)
          @signal = Signal.from(sound)
          @times = @hz = Numo::DFloat[]
          @direction = nil
          @valid = false
          track
        end

        # True if the cycles were followed (see .of).
        def valid? = @valid

        # The frequency (Hz) +seconds+ after the onset (linear between
        # cycles; the first or last cycle's outside them).
        def at(seconds)
          s = Length.seconds(seconds, sample_rate: Signal::RATE).to_f
          return @hz[0] if s <= @times[0]
          return @hz[-1] if s >= @times[-1]
          i = @times.lt(s).where[-1]
          f = (s - @times[i]) / (@times[i + 1] - @times[i])
          @hz[i] + (@hz[i + 1] - @hz[i]) * f
        end

        # The first and last frequencies (medians of three cycles).
        def from = DSP.median(@hz.to_a.first(3))
        def to = DSP.median(@hz.to_a.last(3))

        # The change from #from to #to in cents.
        def cents = 1200 * Math.log2(to / from)

        # Seconds after the onset until the pitch has covered half of its
        # change in cents (nil when steady).
        def half_time
          return nil if @direction == :steady
          half = from * 2**(cents / 2400.0)
          i = @direction == :falling ? @hz.le(half).where[0] : @hz.ge(half).where[0]
          i && @times[i].seconds
        end

        def to_s
          return 'pitch envelope: not followed' unless @valid
          if @direction == :steady
            "pitch envelope steady at #{Analysis.hz_label(from)} over #{Analysis.seconds_label(@times[-1])}"
          else
            pts = [0.01, 0.03, 0.1].select { |s| s < @times[-1] }.map { |s| "#{Analysis.hz_label(at(s))} at #{Analysis.seconds_label(s)}" }
            "pitch envelope #{@direction == :falling ? 'falls' : 'rises'} from #{Analysis.hz_label(from)} to #{Analysis.hz_label(to)} " \
              "(#{format('%+.0f', cents)} cents; #{pts.join(', ')}; half of it by #{Analysis.seconds_label(half_time.to_f)})"
          end
        end

        def inspect = "#<#{self.class.name.sub('MB::Sound::', '')} #{self}>"

        def to_h = { direction: @direction, from_hz: @valid ? from : nil, to_hz: @valid ? to : nil, half_time: half_time&.to_f, times: @times.to_a, hz: @hz.to_a }

        private

        def track
          rate = Signal::RATE
          x = @signal.data
          on = @signal.onset
          stop = [on + (WINDOW * rate).round, x.length].min
          return if stop - on < 2048
          seg = x[on...stop]
          cut = 1.5 * [peak_hz(seg[0...[1440, seg.length].min]), peak_hz(seg[[seg.length - 4096, 0].max..])].max
          return if cut <= 0
          lp = DSP.brickwall(seg, rate, cut)
          up = ((lp[0...-1].le(0)) & (lp[1..-1].gt(0))).where.to_a
          # Interpolated crossing positions
          pos = up.map { |i| i + lp[i] / (lp[i] - lp[i + 1]) }
          return if pos.length < MIN_CYCLES + 1
          per = pos.each_cons(2).map { |a, b| b - a }
          t = pos.each_cons(2).map { |a, b| (a + b) / 2.0 / rate }
          # Low-level stretches (cycles under 1% of the window's peak) and
          # periods outside 20 Hz..5 kHz don't count
          amp = lp.abs.max
          keep = per.each_index.select { |i|
            f = rate / per[i]
            a = pos[i].floor
            b = [pos[i + 1].ceil, lp.length - 1].min
            f.between?(20, 5000) && lp[a..b].abs.max >= 0.01 * amp
          }
          return if keep.length < MIN_CYCLES
          # A pitch moves smoothly from cycle to cycle (a sweep's periods
          # change by a steady ratio); noise's crossings don't
          lp_per = keep.map { |i| Math.log2(per[i]) }
          jitter = DSP.median(lp_per.each_cons(3).map { |a, b, c| (a - 2 * b + c).abs })
          return if jitter.nil? || jitter > MAX_JITTER
          @times = Numo::DFloat.cast(keep.map { |i| t[i] }).freeze
          @hz = Numo::DFloat.cast(keep.map { |i| rate / per[i] }).freeze
          body = @signal.pitch_contour.median
          if body
            # (an octave off is still the same note's cycles)
            off = (1200 * Math.log2(to / body.frequency)).abs % 1200
            return if off > 100 && off < 1100
          end
          c = cents
          @direction = c.abs < 100 ? :steady : (c < 0 ? :falling : :rising)
          @valid = true
        end

        # The frequency of the strongest bin of +seg+ (Hann, zero-padded to
        # 8192), or 0.
        def peak_hz(seg)
          return 0.0 if seg.length < 64
          buf = Numo::DFloat.zeros(8192)
          n = [seg.length, 8192].min
          buf[0...n] = seg[0...n] * DSP.hann(n)
          m = Numo::Pocketfft.rfft(buf).abs
          m[0] = 0
          m.max > 0 ? m.max_index * Signal::RATE / 8192.0 : 0.0
        end
      end
    end
  end
end
