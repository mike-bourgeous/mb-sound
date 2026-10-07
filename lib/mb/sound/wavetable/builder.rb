module MB
  module Sound
    class Wavetable
      # Builds the band-limited levels (mipmaps) of a Wavetable from its
      # spectra (cycle mode) or its audio (sample mode).  See Wavetable for
      # the level layout.
      module Builder
        module_function

        # Returns the harmonic spectra of +frames+ (a 2D NArray, one cycle per
        # row) as a DComplex [frames, harmonics + 1]: column 0 is the DC
        # value, column h the complex amplitude c of harmonic h, so a row is
        # c0 + Re(sum(c * e^(2 pi i h phase))) (or without Re for an analytic
        # table).  The Nyquist bin of an even-length frame is left out (its
        # phase is unknown).  Complex frames keep their positive frequencies.
        def spectra_from_frames(frames)
          frames = frames.reshape(1, frames.length) if frames.ndim == 1
          rows, n = frames.shape
          harmonics = (n - 1) / 2

          spectra = Numo::DComplex.zeros(rows, harmonics + 1)
          rows.times do |r|
            row = frames[r, nil]
            if row.is_a?(Numo::SComplex) || row.is_a?(Numo::DComplex)
              bins = Numo::Pocketfft.fft(Numo::DComplex.cast(row))
              spectra[r, 0] = bins[0] / n
              spectra[r, 1..] = bins[1..harmonics] / n if harmonics > 0
            else
              bins = Numo::Pocketfft.rfft(Numo::DFloat.cast(row))
              spectra[r, 0] = bins[0].real / n
              spectra[r, 1..] = bins[1..harmonics] * (2.0 / n) if harmonics > 0
            end
          end

          spectra
        end

        # Returns the spectra (see spectra_from_frames) of sine harmonics
        # with +amplitudes+ (an Array or 1D NArray, the first for harmonic 1,
        # or an Array of them for several frames) and +phases+ (radians, the
        # same shape, or nil for 0: every harmonic a sine starting at 0).
        def spectra_from_harmonics(amplitudes, phases = nil)
          amps = to_rows(amplitudes)
          phs = phases.nil? ? amps.map { |r| Array.new(r.length, 0.0) } : to_rows(phases)
          raise ArgumentError, 'Amplitudes and phases need the same number of frames' unless phs.length == amps.length

          amps.each_with_index do |row, r|
            raise ArgumentError, "Frame #{r} has #{phs[r].length} phases for #{row.length} amplitudes" unless phs[r].length == row.length
          end

          harmonics = amps.map(&:length).max
          MB::Sound::FastWavetable.harmonic_spectra(Numo::DComplex.zeros(amps.length, harmonics + 1), amps, phs)
        end

        # Ruby mirror of FastWavetable.harmonic_spectra (see
        # .spectra_from_harmonics).
        def spectra_from_harmonics_ruby(amplitudes, phases = nil)
          amps = to_rows(amplitudes)
          phs = phases.nil? ? amps.map { |r| Array.new(r.length, 0.0) } : to_rows(phases)
          harmonics = amps.map(&:length).max
          spectra = Numo::DComplex.zeros(amps.length, harmonics + 1)
          amps.each_with_index do |row, r|
            row.each_with_index do |a, i|
              # a * sin(2 pi h x + p) = Re(a * e^(i (p - pi / 2)) * e^(2 pi i h x))
              spectra[r, i + 1] = Complex.polar(a.to_f, phs[r][i].to_f - Math::PI / 2)
            end
          end

          spectra
        end

        # An Array of Arrays of Floats from one row or several (Arrays or
        # NArrays).
        def to_rows(data)
          data = data.to_a if data.is_a?(Numo::NArray)
          raise ArgumentError, 'Harmonics must be an Array or NArray' unless data.is_a?(Array)
          return [data.map(&:to_f)] if data.empty? || data[0].is_a?(Numeric)

          data.map { |r| (r.is_a?(Numo::NArray) ? r.to_a : r).map(&:to_f) }
        end

        # Synthesizes one cycle of every frame of +spectra+ with harmonics
        # 1..+harmonics+ (default all) at +length+ samples (2D SFloat, or
        # SComplex if +complex+), with each harmonic boosted for the
        # interpolator +emphasis+ (:optimal or :sinc; nil for none; see
        # Emphasis) and scaled by +taper+ (see .taper_gains).
        def synthesize(spectra, length, complex: false, harmonics: nil, emphasis: nil, taper: nil)
          rows, cols = spectra.shape
          harmonics ||= cols - 1
          harmonics = [harmonics, cols - 1, complex ? length - 1 : (length - 1) / 2].min
          if taper
            spectra = spectra[true, 0..harmonics] * taper_gains(taper, harmonics).reshape(1, harmonics + 1)
          end
          if emphasis
            spectra = spectra[true, 0..harmonics] * Emphasis.gains(harmonics + 1, length, emphasis).reshape(1, harmonics + 1)
          end

          out = (complex ? Numo::SComplex : Numo::SFloat).zeros(rows, length)
          rows.times do |r|
            if complex
              bins = Numo::DComplex.zeros(length)
              bins[0] = spectra[r, 0] * length
              bins[1..harmonics] = spectra[r, 1..harmonics] * length if harmonics > 0
              out[r, nil] = Numo::Pocketfft.ifft(bins)
            elsif length.odd?
              # irfft only makes even lengths
              bins = Numo::DComplex.zeros(length)
              bins[0] = spectra[r, 0].real * length
              if harmonics > 0
                bins[1..harmonics] = spectra[r, 1..harmonics] * (length / 2.0)
                bins[(length - harmonics)..] = (spectra[r, 1..harmonics] * (length / 2.0)).conj.reverse
              end
              out[r, nil] = Numo::Pocketfft.ifft(bins).real
            else
              bins = Numo::DComplex.zeros(length / 2 + 1)
              bins[0] = spectra[r, 0].real * length
              bins[1..harmonics] = spectra[r, 1..harmonics] * (length / 2.0) if harmonics > 0
              out[r, nil] = Numo::Pocketfft.irfft(bins)
            end
          end

          out
        end

        # Shifts each frame of +spectra+ after the first in time (circularly,
        # which keeps its sound) to line up with the frame before it, by the
        # shift that maximizes their correlation (within 1 / +resolution+
        # cycle), so scanning between frames doesn't cancel harmonics that
        # merely sit at different phases.  Returns a new DComplex.
        def align(spectra, resolution: 4096)
          rows, cols = spectra.shape
          return spectra.dup if rows < 2 || cols < 2

          out = spectra.dup
          h = Numo::DFloat.new(cols).seq
          (1...rows).each do |r|
            prev = out[r - 1, nil]
            cur = out[r, nil]

            # Correlation at shift s: Re(sum(conj(prev_h) * cur_h * e^(2 pi i h s)))
            bins = Numo::DComplex.zeros(resolution)
            n = [cols, resolution].min
            bins[1...n] = prev[1...n].conj * cur[1...n]
            corr = Numo::Pocketfft.ifft(bins).real
            next if corr.abs.max == 0

            shift = corr.max_index.to_f / resolution
            out[r, nil] = cur * Numo::NMath.exp(h * (2i * Math::PI * shift))
            out[r, 0] = cur[0]
          end

          out
        end

        # The mean of the first half of each frame's cycle minus the mean of
        # the second half, halved (DFloat [frames]): a phase warp of width w
        # moves a frame's DC offset by this times (2w - 1) (see
        # Tone#pwm).  Only odd harmonics count.
        def half_means(spectra)
          rows, cols = spectra.shape
          out = Numo::DFloat.zeros(rows)
          return out if rows == 0

          MB::Sound::FastWavetable.half_means(out, Numo::DComplex.cast(spectra).then { |s| s.contiguous? ? s : s.dup })
        end

        # Ruby mirror of FastWavetable.half_means (see .half_means).
        def half_means_ruby(spectra)
          rows, cols = spectra.shape
          out = Numo::DFloat.zeros(rows)
          rows.times do |r|
            sum = 0.0
            (1...cols).step(2) do |h|
              sum += (2i * spectra[r, h] / (Math::PI * h)).real
            end
            out[r] = sum
          end
          out
        end

        # Gains for harmonics 0..+harmonics+ (a DFloat) of a level that stops
        # at +harmonics+: for +taper+ :sigma, Lanczos's sigma factors
        # sinc(h / (harmonics + 1)), which smooth away the Gibbs overshoot of
        # a truncated series (the waveform is averaged over the width of its
        # top harmonic's period), so peaks stay near the unlimited shape's at
        # every level.
        def taper_gains(taper, harmonics)
          raise ArgumentError, "Unknown taper #{taper.inspect} (:sigma or nil)" unless taper == :sigma

          h = Numo::DFloat.new(harmonics + 1).seq
          x = h * (Math::PI / (harmonics + 1))
          g = Numo::NMath.sin(x) / x
          g[0] = 1.0
          g
        end

        # The harmonic counts of the levels of a cycle table with +harmonics+
        # harmonics: +spacing+ is a ratio (> 1) between levels, or an Array of
        # counts.
        def level_harmonics(harmonics, spacing)
          return spacing.map(&:to_i).select(&:positive?).uniq.sort.reverse if spacing.is_a?(Array)

          counts = []
          h = harmonics.to_f
          while (h + 1e-9).floor >= 1
            c = (h + 1e-9).floor
            counts << c unless counts.last == c
            h /= spacing
          end
          counts
        end

        # Storage length (samples per cycle) of a level with +harmonics+
        # harmonics: OVERSAMPLE times the Nyquist rate, as a power of two.
        def level_length(harmonics)
          n = 2 * OVERSAMPLE * harmonics
          len = MIN_LENGTH
          len *= 2 while len < n
          len
        end

        # Adds GUARD samples before and after each row of a periodic +frames+
        # (wrapped around), so lookups near the ends need no wrapping.
        def wrap_guard(frames)
          rows, n = frames.shape
          out = frames.class.zeros(rows, n + 2 * GUARD)
          if n >= GUARD
            out[true, GUARD...(GUARD + n)] = frames
            out[true, 0...GUARD] = frames[true, (n - GUARD)...n]
            out[true, (GUARD + n)..] = frames[true, 0...GUARD]
            return out
          end

          rows.times do |r|
            row = frames[r, nil]
            out[r, GUARD...(GUARD + n)] = row
            GUARD.times do |g|
              out[r, GUARD - 1 - g] = row[(n - 1 - g) % n]
              out[r, GUARD + n + g] = row[g % n]
            end
          end
          out
        end

        # Builds the cycle-mode levels: [datas, lengths, bandwidths] (see
        # .synthesize for +emphasis+).
        def cycle_levels(spectra, spacing, complex, emphasis, taper = nil)
          harmonics = spectra.shape[1] - 1
          raise ArgumentError, 'A band-limited table needs at least one harmonic' if harmonics < 1

          counts = level_harmonics(harmonics, spacing)
          datas = []
          lengths = []
          counts.each do |h|
            len = level_length(h)
            datas << wrap_guard(synthesize(spectra, len, complex: complex, harmonics: h, emphasis: emphasis, taper: taper))
            lengths << len
          end

          [datas, lengths, counts.map(&:to_f)]
        end

        # The gains of frequencies +freqs+ (cycles per source sample) in a
        # sample level band-limited to +band+: 1 up to (1 - SAMPLE_TRANSITION)
        # * band, a raised cosine down to 0 at +band+ (all 1 for the full
        # band).
        def band_mask(freqs, band)
          return Numo::DFloat.ones(freqs.length) if band >= 0.5 # the full band: nothing to remove

          knee = band * (1.0 - SAMPLE_TRANSITION)
          t = ((freqs - knee) / (band - knee)).clip(0, 1)
          (Numo::NMath.cos(t * Math::PI) + 1) * 0.5
        end

        # Band-limits +data+ (1D, real or complex) to +band+ cycles per
        # sample and resamples it to +new_length+ samples by FFT (treating it
        # as periodic; callers pad with zeros where it isn't).  Returns a 1D
        # SFloat or SComplex (complex if +complex+; a real input then becomes
        # analytic).  With +emphasis+ (:optimal or :sinc), frequencies are
        # boosted for that interpolator (see Emphasis).
        def resample_band(data, band, new_length, complex, emphasis = nil)
          n = data.length
          if complex
            bins = Numo::Pocketfft.fft(Numo::DComplex.cast(data))
            freqs = Numo::DFloat.new(n).seq / n
            freqs[(n / 2 + 1)..] = freqs[(n / 2 + 1)..] - 1 if n > 2
            keep = band_mask(freqs, band)
            keep[freqs.lt(0)] = 0 # analytic: no negative frequencies
            bins = bins * keep
            unless data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
              # A real input's positive frequencies carry half its energy
              # (except Nyquist, which has no negative twin)
              pos = (freqs.gt(0) & freqs.lt(0.5)).where
              bins[pos] = bins[pos] * 2 unless pos.empty?
            end

            out = Numo::DComplex.zeros(new_length)
            half = [n / 2, new_length / 2].min
            out[0..half] = bins[0..half]
            out[0..half] = out[0..half] * Emphasis.gains(half + 1, new_length, emphasis) if emphasis
            Numo::SComplex.cast(Numo::Pocketfft.ifft(out) * (new_length.to_f / n))
          else
            bins = Numo::Pocketfft.rfft(Numo::DFloat.cast(data))
            freqs = Numo::DFloat.new(bins.length).seq / n
            bins = bins * band_mask(freqs, band)

            out = Numo::DComplex.zeros(new_length / 2 + 1)
            m = [bins.length, out.length].min
            out[0...m] = bins[0...m]
            # An even-length input's Nyquist bin stands for both of its
            # sides; above the new Nyquist it is an ordinary bin
            out[n / 2] = out[n / 2] * 0.5 if n.even? && new_length > n && n / 2 < m
            out = out * Emphasis.gains(out.length, new_length, emphasis) if emphasis
            Numo::SFloat.cast(Numo::Pocketfft.irfft(out)[0...new_length] * (new_length.to_f / n))
          end
        end

        # Builds the sample-mode levels of +data+ (1D audio): [levels,
        # loop_levels] of Hashes (data: 2D [1, count + 2 * GUARD], count:,
        # rate:, bandwidth: in cycles per source sample).  +loop+ is a Range
        # of whole source samples, or nil.
        def sample_levels(data, spacing, complex, loop, sample_rate, emphasis)
          n = data.length
          ls, le = loop ? [loop.begin, loop.end] : [nil, nil]
          bands = []
          b = 0.5
          ratio = spacing.is_a?(Array) ? 2.0 : spacing
          while bands.length < MAX_LEVELS && (bands.empty? || b * sample_rate >= MIN_SAMPLE_BAND)
            bands << b
            b /= ratio
          end

          # Attack (or the whole one-shot): the audio before the loop with the
          # loop repeated after it (so the band-limited start of the loop is
          # right), or the whole sound with silence after it
          if loop
            period = data[ls...le]
            reps = [(4 * GUARD / period.length.to_f).ceil + 1, 2].max
            parts = Array.new(reps) { period }
            parts.unshift(data[0...ls]) if ls > 0
            head = parts[0].concatenate(*parts[1..])
            valid = ls
          else
            head = data
            valid = n
          end
          pad = 4096
          total = 1
          total *= 2 while total < head.length + pad
          padded = head.class.zeros(total)
          padded[0...head.length] = head

          levels = bands.map { |band|
            rate = 2.0 * OVERSAMPLE * band
            new_total = (total * rate / 2).round * 2
            rate = new_total.to_f / total
            res = resample_band(padded, band, new_total, complex, emphasis)
            count = (valid * rate).ceil
            row = res.class.zeros(count + 2 * GUARD)
            idx = Numo::Int64.new(count + 2 * GUARD).seq - GUARD
            row[true] = res[idx % new_total]
            { data: row.reshape(1, row.length), count: count, rate: rate, bandwidth: band }
          }

          loop_levels = loop && bands.map { |band|
            len = le - ls
            m = [(len * OVERSAMPLE * band).round * 2, 8].max
            res = resample_band(data[ls...le], band, m, complex, emphasis)
            { data: wrap_guard(res.reshape(1, m)), count: m, rate: m.to_f / len, bandwidth: band }
          }

          [levels, loop_levels]
        end
      end
    end
  end
end
