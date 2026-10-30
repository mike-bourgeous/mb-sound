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
          @bands ||= begin
            f = STFT.bin_freqs(N_FFT, @sample_rate)
            total = @power.sum
            CENTERS.select { |c| c * 2**(1 / 6.0) < @sample_rate / 2 }.to_h { |c|
              lo = c * 2**(-1 / 6.0)
              hi = c * 2**(1 / 6.0)
              sel = (f.ge(lo) & f.lt(hi)).where
              p = sel.size > 0 ? @power[sel].sum : 0.0
              [c, p > 0 && total > 0 ? 10 * Math.log10(p / total) : -Float::INFINITY]
            }.freeze
          end
        end

        # The tilt in dB per octave: the least-squares slope of the band
        # levels in TILT_RANGE against log2 of their centers (0.0 for
        # silence).
        def tilt
          @tilt ||= begin
            pts = bands.select { |c, v| TILT_RANGE.cover?(c) && v.finite? }.map { |c, v| [Math.log2(c / 1000.0), v] }
            if pts.length < 2
              0.0
            else
              mx = pts.sum(&:first) / pts.length
              my = pts.sum(&:last) / pts.length
              sxx = pts.sum { |x, _| (x - mx)**2 }
              (pts.sum { |x, y| (x - mx) * (y - my) } / sxx).round(3)
            end
          end
        end

        def inspect
          "#<#{self.class} tilt #{format('%+.2f', tilt)} dB/oct, #{@frames} of #{@total_frames} frames>"
        end
      end
    end
  end
end
