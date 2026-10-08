module MB
  module Sound
    class Wavetable
      # Perceived loudness of wavetables, for matching tables to each other
      # (Wavetable.from_harmonics(normalize: :loudness), KeyMap.new(normalize:
      # :loudness)): the K-weighted power of a table's harmonics as played at
      # a range of pitches, in dB (an LUFS-like measure of one steady note;
      # BS.1770's K weighting is a +4 dB shelf above about 1.5 kHz and a
      # highpass below about 60 Hz, so bright tables count louder than their
      # RMS and bass harmonics count less).  Computed from the spectra, so
      # it's exact and cheap (no rendering).
      #
      # TODO: use the BS.1770 loudness tool from the lufs branch once it lands
      # (this is a simple internal K weighting at 48 kHz).
      module Loudness
        module_function

        # BS.1770-4 K-weighting at 48 kHz: [[b0, b1, b2], [1, a1, a2]] for the
        # high shelf (stage 1) and the RLB highpass (stage 2).
        K_SHELF = [[1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585]].freeze
        K_HIGHPASS = [[1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621]].freeze

        # The pitches (Hz) a cycle table's loudness is averaged over by
        # default: C2, C3, C4, C5, C6 (the power mean, so a table that is loud
        # at some pitches counts louder).
        PITCHES = [36, 48, 60, 72, 84].map { |n| 440.0 * 2**((n - 69) / 12.0) }.freeze

        # Harmonics above this (Hz) don't count (the levels leave them out).
        LIMIT = 20000.0

        # The power gain of the K weighting at +freq+ Hz (|H|² of both
        # stages at 48 kHz).
        def k_power(freq)
          w = 2 * Math::PI * freq / 48000.0
          [K_SHELF, K_HIGHPASS].reduce(1.0) { |g, (b, a)| g * biquad_power(b, a, w) }
        end

        def biquad_power(b, a, w)
          z1 = Complex.polar(1.0, -w)
          z2 = Complex.polar(1.0, -2 * w)
          ((b[0] + b[1] * z1 + b[2] * z2) / (a[0] + a[1] * z1 + a[2] * z2)).abs2
        end

        # K-weighted power of one frame's spectrum +row+ (DComplex of [DC,
        # harmonic 1, ...], as in Builder.spectra_from_frames) played at
        # +pitch+ Hz: the sum over harmonics below LIMIT of |c_h|² / 2 times
        # the weighting (the power of the real part, for complex tables
        # too).
        def frame_power(row, pitch)
          top = [(LIMIT / pitch).floor, row.length - 1].min
          return 0.0 if top < 1

          h = Numo::DFloat.new(top).seq(1)
          weights = Numo::DFloat.cast(h.to_a.map { |n| k_power(n * pitch) })
          (Numo::DFloat.cast(row[1..top].abs**2) * weights).sum * 0.5
        end

        # The loudness in dB of a cycle table's frame +row+ (spectrum) over
        # +pitches+ (Hz): 10 log10 of the mean K-weighted power.
        def frame_db(row, pitches = PITCHES)
          power = pitches.sum { |p| frame_power(row, p) } / pitches.length
          power > 0 ? 10 * Math.log10(power) : -Float::INFINITY
        end

        # The loudness in dB of each frame of a cycle table's +spectra+
        # (DComplex [frames, harmonics + 1]) over +pitches+.
        def spectra_db(spectra, pitches = PITCHES)
          Array.new(spectra.shape[0]) { |r| frame_db(spectra[r, true], pitches) }
        end

        # The reference loudness that normalize: :loudness matches (the
        # library saw's; classic shapes keep their exact series), in dB.
        def reference_db
          @reference_db ||= frame_db(Builder.spectra_from_harmonics(Library.saw)[0, true])
        end

        # Gains (an Array) that bring each frame of +spectra+ to
        # reference_db.  Silent frames keep a gain of 1.
        def normalizing_gains(spectra)
          ref = reference_db
          spectra_db(spectra).map { |db| db.finite? ? 10**((ref - db) / 20.0) : 1.0 }
        end

        # The loudness in dB of a sample-mode +data+ (a 1D NArray at
        # +sample_rate+ with its root at +root+ Hz) played with its root at
        # +pitch+ Hz: the K-weighted power of its spectrum, frequencies
        # scaled by pitch / root.
        def sample_db(data, sample_rate, root, pitch)
          d = Numo::DFloat.cast(data.respond_to?(:real) && !data.is_a?(Numo::DFloat) && !data.is_a?(Numo::SFloat) ? data.real : data)
          return -Float::INFINITY if d.length < 2

          bins = Numo::Pocketfft.rfft(d)
          n = d.length
          freqs = Numo::DFloat.new(bins.length).seq * (sample_rate.to_f / n) * (pitch / root.to_f)
          weights = Numo::DFloat.cast(freqs.to_a.map { |f| f > 0 && f < LIMIT ? k_power(f) : 0.0 })
          power = ((bins.abs**2) * weights).sum * 2.0 / (n.to_f * n)
          power > 0 ? 10 * Math.log10(power) : -Float::INFINITY
        end
      end
    end
  end
end
