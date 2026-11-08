module MB
  module Sound
    module Analysis
      # The long-term average spectrum of a signal and its tilt: the power
      # of 8192-point Hann frames every 4096 samples (frames more than
      # GATE dB under the loudest left out, so silence and fades don't
      # count), summed into third-octave bands, and the slope of a straight
      # line through the bands' levels in dB against octaves between 100
      # Hz and 10 kHz (dB per octave).  Bands integrate power, so pink
      # noise (equal power per octave) has tilt 0 and white noise +3; mixed
      # music usually sits between -2 and +1 (bright, dense masters
      # higher).  The :match mastering preset (master_effects.md) matches a
      # reference's tilt with Mastering.tilt_eq.
      #
      #     sp = Analysis::Spectrum.new(channels, sample_rate: 48000)
      #     sp.tilt       # => -1.2 (dB/octave)
      #     sp.bands      # => { 50.0 => -31.2, 63.0 => ..., } dB re the total
      class Spectrum
        N_FFT = 8192
        HOP = 4096

        # Frames this many dB under the loudest frame don't count.
        GATE = 40.0

        # The tilt's fit range (Hz).
        TILT_RANGE = 100.0..10000.0

        # Third-octave band centers (Hz, IEC 61260 nominal, 25 Hz to 20
        # kHz).
        CENTERS = [25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
                   2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000].map(&:to_f).freeze

        # Octave band centers (Hz, IEC 61260 nominal, 31.5 Hz to 16 kHz).
        OCTAVE_CENTERS = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map(&:to_f).freeze

        attr_reader :sample_rate

        # The gated mean power spectrum (n_fft / 2 + 1 bins, Numo::DFloat).
        attr_reader :power

        # Frames counted and frames in all.
        attr_reader :frames, :total_frames

        # Measures +data+ (a Numo array or an Array of channels, mixed down).
        def initialize(data, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          mono = Analysis.mono(data)
          # The gate from the frames' energies first (time domain, so the
          # spectra are summed in one pass without keeping them)
          energy = STFT.frame_energies(mono, n_fft: N_FFT, hop: HOP)
          top = energy.max
          keep = top > 0 ? energy.ge(top * 10**(-GATE / 10)) : nil
          @total_frames = energy.size
          @frames = keep ? keep.count_true : 0
          sum = Numo::DFloat.zeros(N_FFT / 2 + 1)
          if @frames > 0
            STFT.each_chunk(mono, n_fft: N_FFT, hop: HOP) do |rows, mag|
              sel = keep[rows].where
              sum += (mag[sel, true]**2).sum(axis: 0) if sel.size > 0
            end
          end
          @power = @frames > 0 ? sum / @frames : sum
          @bands = nil
          @tilt = nil
        end

        # Third-octave band levels: { center Hz => dB re the total power }
        # (bands past Nyquist left out; -inf for empty bands).
        def bands
          @bands ||= Spectrum.band_levels(@power, @sample_rate)
        end

        # The tilt in dB per octave: the least-squares slope of the band
        # levels in TILT_RANGE against log2 of their centers (0.0 for
        # silence).
        def tilt
          @tilt ||= Spectrum.tilt_of(bands)
        end

        # Band levels of a power spectrum +power+ (n_fft / 2 + 1 bins at
        # +sample_rate+): { center Hz => dB re +reference+ (the total power
        # by default) }, +centers+ +per_octave+ to the octave (third
        # octaves by default, OCTAVE_CENTERS with 1), each band summing
        # the bins within half a band of its center; bands past Nyquist
        # left out, -inf for empty ones.  Bar statistics read each beat's
        # spectrum with it (BarStats).
        def self.band_levels(power, sample_rate, centers: CENTERS, per_octave: 3, reference: nil)
          n_fft = (power.length - 1) * 2
          kept, map = band_map(n_fft, sample_rate, centers: centers, per_octave: per_octave)
          total = reference || power.sum
          sums = power.dot(map)
          kept.each_with_index.to_h { |c, i|
            p = sums[i]
            [c, p > 0 && total > 0 ? 10 * Math.log10(p / total) : -Float::INFINITY]
          }.freeze
        end

        # The bands of #band_levels for +n_fft+-point spectra: [centers
        # kept (under Nyquist), a (n_fft / 2 + 1) x centers 0/1 DFloat
        # whose columns pick each band's bins] (cached), so frames x bins
        # powers dot the map give frames x bands.
        def self.band_map(n_fft, sample_rate, centers: CENTERS, per_octave: 3)
          @band_maps ||= {}
          @band_maps[[n_fft, sample_rate.to_f, centers, per_octave]] ||= begin
            f = STFT.bin_freqs(n_fft, sample_rate)
            up = 2**(1 / (2.0 * per_octave))
            down = 2**(-1 / (2.0 * per_octave))
            kept = centers.select { |c| c * up < sample_rate / 2.0 }
            map = Numo::DFloat.zeros(f.length, [kept.length, 1].max)
            kept.each_with_index { |c, i| map[(f.ge(c * down) & f.lt(c * up)).where, i] = 1.0 }
            [kept.freeze, map.freeze].freeze
          end
        end

        # The least-squares slope (dB per octave, rounded to 0.001) of band
        # levels +levels+ ({ center Hz => dB }) in TILT_RANGE against log2
        # of their centers; 0.0 with fewer than two finite bands.  Bands
        # integrate power, so third octaves and octaves give the same
        # slope.
        def self.tilt_of(levels)
          pts = levels.select { |c, v| TILT_RANGE.cover?(c) && v.finite? }.map { |c, v| [Math.log2(c / 1000.0), v] }
          return 0.0 if pts.length < 2

          mx = pts.sum(&:first) / pts.length
          my = pts.sum(&:last) / pts.length
          sxx = pts.sum { |x, _| (x - mx)**2 }
          (pts.sum { |x, y| (x - mx) * (y - my) } / sxx).round(3)
        end

        def inspect
          "#<#{self.class} tilt #{format('%+.2f', tilt)} dB/oct, #{@frames} of #{@total_frames} frames>"
        end
      end
    end
  end
end
