require 'numo/pocketfft'

module MB
  module Sound
    class Sample
      # Frequency-domain time-stretching for Sample#stretch (see
      # design/notes/granular.md): a phase vocoder with identity phase
      # locking and transient handling (mode: :spectral), and Paulstretch
      # (mode: :paul).  Offline, vectorized with Numo and Pocketfft; every
      # function takes and returns an Array of channels (DFloats).
      module Spectral
        # Stretch modes (Sample#stretch) and their other names.
        MODES = [:cyclic, :spectral, :paul].freeze
        MODE_ALIASES = { pv: :spectral, vocoder: :spectral, phase_vocoder: :spectral, paulstretch: :paul, lofi: :cyclic, s950: :cyclic }.freeze

        # The phase vocoder's default window (samples) and overlap.
        WINDOW = 4096
        OVERLAP = 4

        # Paulstretch's default window (seconds).
        PAUL_WINDOW = 0.25

        TWO_PI = 2 * Math::PI

        module_function

        # +mode+ as a MODES name.
        def mode_name(mode)
          m = mode.to_sym
          m = MODE_ALIASES.fetch(m, m)
          raise ArgumentError, "Unknown stretch mode #{mode.inspect} (#{(MODES + MODE_ALIASES.keys).map(&:inspect).join(', ')})" unless MODES.include?(m)
          m
        end

        # A periodic Hann window of +n+ samples.
        def hann(n)
          Numo::DFloat.new(n).seq.tap { |x| x.inplace * (TWO_PI / n) }.then { |x| (1 - Numo::NMath.cos(x)) * 0.5 }
        end

        # The +n+ samples of +x+ centered on +center+ (zeros outside).
        def segment(x, center, n)
          s = center - n / 2
          out = Numo::DFloat.zeros(n)
          a = [s, 0].max
          b = [s + n, x.length].min
          out[(a - s)...(b - s)] = x[a...b] if b > a
          out
        end

        # Phase vocoder stretch of +channels+ by +ratio+ (see
        # design/notes/granular.md): Hann windows of +window+ samples,
        # +overlap+ frames per window, identity phase locking around
        # spectral peaks, one phase rotation (computed on the channels'
        # mix) for every channel, and +onsets+ (sample positions; nil for
        # none) kept unstretched with a phase reset.
        def vocoder(channels, ratio, window: WINDOW, overlap: OVERLAP, onsets: nil)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          n = Integer(window)
          raise ArgumentError, "The window must be an even number of samples, 64 or more (got #{window})" unless n >= 64 && n.even?
          hs = n / Integer(overlap)
          raise ArgumentError, 'The overlap must leave a hop of at least 8 samples' unless hs >= 8

          xs = channels.map { |c| Numo::DFloat.cast(c) }
          len = xs[0].length
          out_len = (len * ratio).round
          mix = xs.length == 1 ? xs[0] : xs.sum / xs.length
          map = time_map(len, ratio, onsets, n, hs)
          w = hann(n)
          nb = n / 2 + 1
          omega = Numo::DFloat.new(nb).seq * (TWO_PI / n)
          hr = n / 8 # the fixed offset for instantaneous frequencies

          frames = out_len / hs + 2
          buf = Array.new(xs.length) { Numo::DFloat.zeros(frames * hs + n) }
          wsum = Numo::DFloat.zeros(frames * hs + n)
          w2 = w * w

          theta = nil
          phi_prev = nil
          prev_center = nil
          resets = onsets ? onsets.sort : []
          ri = 0

          frames.times do |m|
            center = map.call(m * hs).round
            spec = Numo::Pocketfft.rfft(segment(mix, center, n) * w)
            phi = spec.arg
            mag = spec.abs

            reset = false
            while ri < resets.length && center + n / 2 > resets[ri]
              reset = true
              ri += 1
            end

            if theta.nil? || reset
              theta = phi.dup
            else
              ha = center - prev_center
              if ha == hs
                # Unstretched frames (around transients): the exact phase
                # difference over the real hop, so the frames rebuild the
                # input
                winst_h = omega * hs + princarg(phi - phi_prev - omega * hs)
              else
                ref = Numo::Pocketfft.rfft(segment(mix, center - hr, n) * w).arg
                winst_h = (omega + princarg(phi - ref - omega * hr) / hr) * hs
              end
              theta = lock(theta + winst_h, phi, mag)
            end
            phi_prev = phi
            prev_center = center

            rot = theta - phi
            rotc = Numo::DComplex.cast(Numo::NMath.cos(rot)) + Numo::NMath.sin(rot) * Complex::I
            pos = m * hs
            xs.each_with_index do |x, ch|
              cs = ch == 0 && xs.length == 1 ? spec : Numo::Pocketfft.rfft(segment(x, center, n) * w)
              y = Numo::Pocketfft.irfft(cs * rotc) * w
              buf[ch][pos...(pos + n)] += y
            end
            wsum[pos...(pos + n)] += w2
          end

          finish(buf, wsum, n, out_len)
        end

        # Identity phase locking (Laroche & Dolson 1999): peak bins keep
        # +advanced+ (their phases moved on by their frequencies); every
        # other bin takes its peak's phase plus its own analysis phase
        # offset from the peak (+phi+), regions split midway between
        # peaks of +mag+.
        def lock(advanced, phi, mag)
          nb = mag.length
          return advanced if nb < 5

          c = mag[2...(nb - 2)]
          is_peak = (c > mag[1...(nb - 3)]) & (c > mag[0...(nb - 4)]) & (c >= mag[3...(nb - 1)]) & (c >= mag[4...nb])
          peaks = is_peak.where + 2
          return advanced if peaks.empty?

          marker = Numo::Int32.zeros(nb)
          if peaks.length > 1
            bounds = ((peaks[0...-1] + peaks[1..]) / 2) + 1
            marker[bounds] = 1
          end
          owner = peaks[marker.cumsum]
          advanced[owner] + (phi - phi[owner])
        end

        # Paulstretch (Nasca Paul) of +channels+ by +ratio+: Hann windows of
        # +window+ samples hopping a quarter window in the output, every
        # bin's magnitude kept and its phase replaced by a random one from
        # +seed+ (shared by the channels).
        def paul(channels, ratio, window:, seed: 0)
          raise ArgumentError, "Stretch ratios are positive (got #{ratio})" unless ratio > 0
          n = Integer(window)
          n += 1 if n.odd?
          raise ArgumentError, "The window must be 64 samples or more (got #{window})" unless n >= 64
          hs = n / 4

          xs = channels.map { |c| Numo::DFloat.cast(c) }
          len = xs[0].length
          out_len = (len * ratio).round
          w = hann(n)
          nb = n / 2 + 1
          frames = out_len / hs + 2
          buf = Array.new(xs.length) { Numo::DFloat.zeros(frames * hs + n) }
          wsum = Numo::DFloat.zeros(frames * hs + n)
          w2 = w * w

          frames.times do |m|
            center = (m * hs / ratio.to_f).round
            ph = random_phases(seed, m, nb) * TWO_PI
            rot = Numo::DComplex.cast(Numo::NMath.cos(ph)) + Numo::NMath.sin(ph) * Complex::I
            pos = m * hs
            xs.each_with_index do |x, ch|
              mag = Numo::Pocketfft.rfft(segment(x, center, n) * w).abs
              y = Numo::Pocketfft.irfft(rot * mag) * w
              buf[ch][pos...(pos + n)] += y
            end
            wsum[pos...(pos + n)] += w2
          end

          # Random-phase frames add up in power, not in amplitude
          finish(buf, wsum, n, out_len, power: (w2.mean).to_f)
        end

        # +count+ uniform numbers in 0...1 for frame +frame+: a splitmix64
        # hash of (seed, frame, bin), so the phases don't depend on how the
        # work is split.
        def random_phases(seed, frame, count)
          base = (Integer(seed) * 0x9E3779B97F4A7C15 + frame * 0xD1B54A32D192ED03) & Tone::MASK64
          z = Numo::UInt64.new(count).seq
          z.inplace * Numo::UInt64[0x9E3779B97F4A7C15]
          z.inplace + Numo::UInt64[base]
          z = (z ^ (z >> 30)) * Numo::UInt64[0xBF58476D1CE4E5B9]
          z = (z ^ (z >> 27)) * Numo::UInt64[0x94D049BB133111EB]
          z = z ^ (z >> 31)
          Numo::DFloat.cast(z >> 11) * 2.0**-53
        end

        # Phases wrapped to -pi...pi.
        def princarg(x)
          x - TWO_PI * ((x + Math::PI) / TWO_PI).floor
        end

        # The overlap-added channels, each divided by the windows' summed
        # squares and cut to +out_len+ (output sample 0 is the first
        # frame's center).  With +power+ (the window's mean square, for
        # incoherent frames), divided by sqrt(sum × power) instead.
        def finish(buf, wsum, n, out_len, power: nil)
          h = n / 2
          floor = wsum.max * 1e-3
          norm = wsum[h...(h + out_len)].dup
          norm[norm < floor] = floor
          norm = Numo::NMath.sqrt(norm * power) if power
          buf.map { |b| b[h...(h + out_len)] / norm }
        end

        # A proc from output position to input position: output / +ratio+,
        # except that each onset's span (a window before through half a
        # window after, plus a hop) plays at ratio 1, the rest stretched
        # more so the total stays +ratio+ times the length.
        def time_map(len, ratio, onsets, n, hs)
          plain = ->(t) { t / ratio.to_f }
          return plain if onsets.nil? || onsets.empty?

          spans = onsets.sort.map { |o| [[o - n / 2 - hs, 0].max, [o + n / 2, len].min] }.reject { |a, b| b <= a }
          merged = []
          spans.each { |a, b| merged.last && a <= merged.last[1] ? merged.last[1] = [merged.last[1], b].max : merged << [a, b] }
          protected_len = merged.sum { |a, b| b - a }
          rest = len - protected_len
          out_total = len * ratio.to_f
          return plain unless rest > 0 && out_total - protected_len > rest * 0.05 * ratio

          ru = (out_total - protected_len) / rest
          ins = [0.0]
          outs = [0.0]
          merged.each do |a, b|
            outs << outs.last + (a - ins.last) * ru
            ins << a.to_f
            outs << outs.last + (b - a)
            ins << b.to_f
          end
          outs << outs.last + (len - ins.last) * ru
          ins << len.to_f

          k = 0
          ->(t) {
            k = 0 if t < outs[k]
            k += 1 while k < outs.length - 2 && t >= outs[k + 1]
            span = outs[k + 1] - outs[k]
            span > 0 ? ins[k] + (t - outs[k]) * (ins[k + 1] - ins[k]) / span : ins[k]
          }
        end
      end
    end
  end
end
