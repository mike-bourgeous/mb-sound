module MB
  module Sound
    module Analysis
      # Room acoustics of an impulse response (conv-reverb-1, 2026-11-06),
      # the measurements ReverbMatch fits the algorithmic reverb to: per
      # octave band, Schroeder's energy decay curve (backward integration)
      # with the noise floor cut off, the reverberation time T60 (from T30,
      # or T20/T10 when the decay range is short), and the early decay time
      # EDT; the onset (predelay), early/late energy (C50, C80), the late
      # tail's spectrum (each band's level at the start of the late decay,
      # extrapolated from its fitted line), and the channels' correlation
      # in the late tail (width).
      #
      #     ir = Analysis::ImpulseResponse.new('hall.wav')
      #     ir.t60            # { 125 => 2.41, 250 => 2.3, ... } seconds
      #     ir.edc(1000)      # DFloat of dB from 0 (band 1 kHz)
      #     ir.onset          # seconds before the impulse starts
      #     ir.c80            # dB, early (first 80 ms) over late energy
      #     ir.tail_levels    # { 125 => dB, ... } late-tail band levels
      #     ir.correlation    # late-tail L/R correlation (nil for mono)
      #
      # Bands are filtered by brick-wall FFT masks (Analysis::DSP), wide
      # enough apart that the filters' ringing stays far below the fits'
      # -5 dB starting point.
      class ImpulseResponse
        # Octave band centers (Hz).
        BANDS = [125, 250, 500, 1000, 2000, 4000, 8000].freeze

        # Where each decay fit starts and the deepest end it tries (dB
        # below the curve's start): T30 (-5..-35), else T20, else T10.
        FITS = [[-5.0, -35.0], [-5.0, -25.0], [-5.0, -15.0]].freeze

        # The start of the late part: this long after the onset (seconds).
        LATE = 0.08

        # The onset is the first sample within this many dB of the peak.
        ONSET_DB = -20.0

        # The channels as DFloats.
        attr_reader :channels

        attr_reader :sample_rate

        # +impulse+ is a file path, a Sample, an NArray (1D, or 2D as
        # [channels, samples]), or an Array of channels at +sample_rate+.
        def initialize(impulse, sample_rate: 48000)
          impulse = Sample[impulse] if impulse.is_a?(String)
          if impulse.is_a?(Sample)
            sample_rate = impulse.sample_rate
            impulse = impulse.to_a
          end
          impulse = (0...impulse.shape[0]).map { |c| impulse[c, true] } if impulse.is_a?(Numo::NArray) && impulse.ndim == 2
          impulse = [impulse] if impulse.is_a?(Numo::NArray) # (Array(narray) would make one channel per sample)
          @channels = impulse.map { |c| Numo::DFloat.cast(c) }
          raise ArgumentError, 'An impulse response needs at least one channel' if @channels.empty?
          @sample_rate = sample_rate.to_f
          @band_cache = {}
          @fit_cache = {}
        end

        # The impulse length in seconds.
        def seconds
          @channels.map(&:length).max / @sample_rate
        end

        # Time (seconds) of the first sample within ONSET_DB of the peak.
        def onset
          @onset ||= begin
            e = energy(nil)
            peak = e.max
            idx = (e >= peak * 10**(ONSET_DB / 10)).where
            idx.empty? ? 0.0 : idx[0] / @sample_rate
          end
        end

        # The energy (summed over channels) of +band+ (Hz center) or the
        # whole impulse (nil).
        def energy(band)
          @band_cache[band] ||= begin
            sum = nil
            @channels.each do |c|
              x = band ? band_filter(c, band) : c
              sum = sum.nil? ? x**2 : sum + x**2
            end
            sum
          end
        end

        # +x+ through the octave band at +band+ Hz: an FFT mask that falls
        # from 1 to 0 over TAPER octaves centered on each edge (a raised
        # cosine in log frequency; neighbors' masks cross at 0.5), so the filter's own
        # response dies away in tens of milliseconds (a brick-wall mask
        # rings as 1/t, which at 125 Hz put a floor near -38 dB under the
        # decay curves).
        def band_filter(x, band)
          spec, n = spectrum_of(x)
          Numo::Pocketfft.irfft(spec * band_mask(band, spec.length, n))[0...x.length].dup
        end

        # The FFT of +x+ zero-padded by at least PAD to a power of two, and
        # that size (cached per channel: every band filters the same one).
        def spectrum_of(x)
          (@spectra ||= {}.compare_by_identity)[x] ||= begin
            n = 2**Math.log2(x.length + PAD).ceil
            xx = Numo::DFloat.zeros(n)
            xx[0...x.length] = x
            [Numo::Pocketfft.rfft(xx), n]
          end
        end

        # The band's FFT mask for +bins+ bins of an +n+-point transform.
        def band_mask(band, bins, n)
          (@masks ||= {})[[band, bins, n]] ||= begin
            f = Numo::DFloat.new(bins).seq * (@sample_rate / n)
            oct = Numo::NMath.log2((f + 1e-9) / band).abs # octaves from the center
            mask = Numo::DFloat.ones(bins)
            taper = TAPER
            edge = 0.5 - taper / 2
            mask[oct > edge + taper] = 0
            mid = ((oct > edge) & (oct <= edge + taper)).where
            mask[mid] = (Numo::NMath.cos((oct[mid] - edge) / taper * Math::PI) + 1) * 0.5 unless mid.empty?
            mask
          end
        end

        # The width of each band edge's taper in octaves (wider rings less,
        # narrower lets less of the neighbors' decay in).
        TAPER = 1.0 / 6

        # Zeros added before band filtering, so the decay doesn't wrap into
        # the start.
        PAD = 16384

        # The noise floor of +band+ (mean energy per sample over the last
        # tenth of the impulse) and the sample where the band's decay meets
        # it (Lundeby's idea, simplified: the 10 ms envelope's last point
        # 5 dB above the floor).
        def noise_cut(band)
          e = energy(band)
          n = e.length
          floor = e[(n * 0.9).floor..].mean
          win = [(0.01 * @sample_rate).round, 1].max
          frames = n / win
          return [floor, n] if frames < 4

          env = e[0...(frames * win)].reshape(frames, win).mean(axis: 1)
          above = (env > floor * 10**0.5).where
          cut = above.empty? ? n : [(above[-1] + 1) * win, n].min
          # a floor this close to the peak means no floor was measured (the
          # impulse decays to its end): keep everything
          if floor < env.max * 1e-9 || cut >= n * 0.9
            [0.0, n]
          else
            [floor, cut]
          end
        end

        # Schroeder's energy decay curve of +band+ (nil: broadband) in dB
        # relative to its start, the noise floor subtracted, to where the
        # decay meets the floor.
        def edc(band = nil)
          @fit_cache[[:edc, band]] ||= begin
            floor, cut = band ? noise_cut(band) : noise_cut(nil)
            e = energy(band)[0...cut] - floor
            e[e < 0] = 0
            s = e.reverse.cumsum.reverse
            DSP.db(s / s[0], 1e-30)
          end
        end

        # [T60, fit] of +band+: the decay time from the deepest fit in FITS
        # the curve reaches, and its [from, to] dB.  nil if the curve doesn't
        # fall 15 dB.
        def decay_fit(band)
          @fit_cache[[:fit, band]] ||= begin
            d = edc(band)
            fit = FITS.find { |_, to| d.min <= to - 1 }
            if fit
              idx = ((d <= fit[0]) & (d >= fit[1])).where
              t = Numo::DFloat.cast(idx) / @sample_rate
              y = d[idx]
              slope = ((t - t.mean) * (y - y.mean)).sum / ((t - t.mean)**2).sum
              intercept = y.mean - slope * t.mean
              [-60.0 / slope, fit, intercept, slope]
            end
          end
        end

        # T60 in seconds per band ({ Hz => seconds or nil }).
        def t60
          BANDS.to_h { |b| [b, decay_fit(b)&.first] }
        end

        # The broadband T60 (seconds).
        def t60_broadband
          decay_fit(nil)&.first
        end

        # The early decay time per band: 6 x the time to fall from 0 to -10
        # dB (seconds).
        def edt
          BANDS.to_h { |b|
            d = edc(b)
            i = (d <= -10).where
            [b, i.empty? ? nil : 6.0 * i[0] / @sample_rate]
          }
        end

        # Clarity: early energy (the first +ms+ ms after the onset) over the
        # rest, in dB (broadband).
        def clarity(ms)
          e = energy(nil)
          s = (onset * @sample_rate).round
          split = [s + (ms * 0.001 * @sample_rate).round, e.length].min
          early = e[s...split].sum
          late = e[split..].sum
          late > 0 ? 10 * Math.log10(early / late) : Float::INFINITY
        end

        def c50 = clarity(50)
        def c80 = clarity(80)

        # Each band's late-tail level (dB, relative to the loudest band):
        # its fitted decay line's value at LATE after the onset, plus the
        # band's total energy (so the levels are of the decaying tail, not
        # the direct sound).
        def tail_levels
          @fit_cache[:tail] ||= begin
            t0 = onset + LATE
            raw = BANDS.to_h { |b|
              f = decay_fit(b)
              total = energy(b).sum
              level = f ? f[2] + f[3] * t0 : edc(b)[[(t0 * @sample_rate).round, edc(b).length - 1].min]
              [b, 10 * Math.log10(total + 1e-300) + level]
            }
            top = raw.values.max
            raw.transform_values { |v| v - top }
          end
        end

        # The correlation of the first two channels over the late tail
        # (nil for one channel): 1 is mono, 0 fully decorrelated.
        def correlation
          return nil if @channels.length < 2

          s = ((onset + LATE) * @sample_rate).round
          a = @channels[0][s..]
          b = @channels[1][s..]
          n = [a.length, b.length].min
          return nil if n < 2
          a = a[0...n]
          b = b[0...n]
          d = Math.sqrt((a**2).sum * (b**2).sum)
          d > 0 ? (a * b).sum / d : nil
        end

        # The measurements as a Hash of plain values.
        def to_h
          {
            seconds: seconds.round(4), onset: onset.round(5), t60: t60.transform_values { |v| v&.round(4) },
            t60_broadband: t60_broadband&.round(4), edt: edt.transform_values { |v| v&.round(4) },
            c50: c50.round(2), c80: c80.round(2), tail_levels: tail_levels.transform_values { |v| v.round(2) },
            correlation: correlation&.round(3), channels: @channels.length,
          }
        end

        def to_s
          t = t60.map { |b, v| "#{b >= 1000 ? "#{b / 1000}k" : b}: #{v ? format('%.2f', v) : '-'}" }.join('  ')
          [
            format('Impulse: %d ch, %.2f s, onset %.1f ms, C50 %.1f dB, C80 %.1f dB%s', @channels.length, seconds, onset * 1000, c50, c80,
              correlation ? format(', late L/R correlation %.2f', correlation) : ''),
            "T60 s  #{t}",
          ].join("\n")
        end
      end
    end
  end
end
