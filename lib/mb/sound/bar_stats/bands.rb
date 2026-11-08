module MB
  module Sound
    module BarStats
      # The low, mid, and high bands bar statistics read timing and stereo
      # in, split at Structure::Frames' onset bands (150 Hz and 2 kHz): two
      # linear-phase windowed-sinc lowpasses (Blackman, TAPS taps), applied
      # by FFT convolution with their delay removed, so each band is zero
      # phase (an onset stays on its sample in every band) and the three
      # bands sum to the signal exactly (low = LP(150), mid = LP(2000) -
      # LP(150), high = x - LP(2000)).
      #
      #     low, mid, high = BarStats::Bands.split(x, 48000)
      module Bands
        # Crossover frequencies in Hz (Structure::Frames' onset bands).
        EDGES = [150.0, 2000.0].freeze

        # Band names, lowest first.
        NAMES = %i[low mid high].freeze

        # Taps of each lowpass (85 ms at 48 kHz: a transition about 65 Hz
        # wide, -74 dB stopband).
        TAPS = 4097

        # Splits +x+ (a Numo array) at +rate+ into NAMES.length bands
        # (DFloats of +x+'s length), or the part of it from sample +from+
        # to +to+ with +margin+ samples either side (zeros past the ends),
        # so a caller reading a slice gets its bands without edge effects.
        def self.split(x, rate, from: 0, to: nil, margin: 0, edges: EDGES)
          x = Numo::DFloat.cast(x)
          to ||= x.length
          a = from - margin
          b = to + margin
          half = TAPS / 2
          # The slice plus half a kernel either side (zeros outside x)
          lo = a - half
          hi = b + half
          seg = Numo::DFloat.zeros(hi - lo)
          s0 = [lo, 0].max
          s1 = [hi, x.length].min
          seg[(s0 - lo)...(s1 - lo)] = x[s0...s1] if s1 > s0

          n = 1
          n *= 2 while n < seg.length + TAPS
          spec = Numo::Pocketfft.rfft(pad(seg, n))
          lows = edges.map { |f| Numo::Pocketfft.irfft(spec * kernel_spectrum(rate, f, n))[(TAPS - 1)...(TAPS - 1 + b - a)].dup }
          body = seg[half...(half + b - a)].dup
          bands = [lows[0]]
          (1...lows.length).each { |i| bands << lows[i] - lows[i - 1] }
          bands << body - lows[-1]
          bands
        end

        # The spectrum of the lowpass at +cutoff+ Hz for +n+-point FFTs
        # (cached).
        def self.kernel_spectrum(rate, cutoff, n)
          @spectra ||= {}
          @spectra[[rate.to_f, cutoff.to_f, n]] ||= Numo::Pocketfft.rfft(pad(kernel(rate, cutoff), n)).freeze
        end

        # The windowed-sinc lowpass at +cutoff+ Hz (TAPS taps, unity DC
        # gain).
        def self.kernel(rate, cutoff)
          m = TAPS - 1
          i = Numo::DFloat.new(TAPS).seq - m / 2.0
          fc = cutoff.to_f / rate
          sinc = Numo::DFloat.new(TAPS).fill(2 * fc)
          nz = i.ne(0)
          sinc[nz] = Numo::NMath.sin(i[nz] * (2 * Math::PI * fc)) / (i[nz] * Math::PI)
          k = Numo::DFloat.new(TAPS).seq * (2 * Math::PI / m)
          win = 0.42 - 0.5 * Numo::NMath.cos(k) + 0.08 * Numo::NMath.cos(k * 2)
          h = sinc * win
          h / h.sum
        end

        # +x+ zero-padded to +n+ samples.
        def self.pad(x, n)
          out = Numo::DFloat.zeros(n)
          out[0...x.length] = x
          out
        end
      end
    end
  end
end
