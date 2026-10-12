module MB
  module Sound
    module Structure
      # Frame features of a mono signal for structure analysis: a 2048-point
      # Hann STFT every 512 samples (93.75 frames per second at 48 kHz),
      # reduced while it runs (the magnitude spectrogram is never kept, so a
      # three-minute song takes about 15 MB) to:
      #
      # +logmel+ - 64 mel bands (30 Hz to 16 kHz) in dB, floored 80 dB below
      #            the loudest value (frames x 64).
      # +mfcc+ - DCT-II coefficients 0..19 of +logmel+ (frames x 20), a
      #          timbre summary.
      # +chroma+ - Magnitude by pitch class (C = 0, A = 9) from 55 Hz to 5
      #            kHz, each bin split between its two nearest semitones
      #            (frames x 12).
      # +bass_chroma+ - The same from 55 to 300 Hz (bass notes and roots).
      # +energy+ - Total power in dB per frame.
      # +band_flux+ - Half-wave rectified log-mel flux averaged in three
      #               bands (below 150 Hz, 150 Hz to 2 kHz, above 2 kHz).
      #
      # Frames are centered on multiples of the hop (frame i at i * hop
      # samples), with half a window of silence before the start, so a note
      # on sample 0 is an onset.
      #
      # Onset envelopes (#onset, #phase_onset) remove each band's 1 s moving
      # average, rectify, and scale to unit deviation before the bands are
      # combined, so the hook or the hats (which dominate a mean over all
      # bands) don't outweigh the kick.
      class Frames
        N_FFT = 2048
        HOP = 512
        N_MEL = 64
        N_MFCC = 20
        MEL_RANGE = 30.0..16000.0
        CHROMA_RANGE = 55.0..5000.0
        BASS_CHROMA_RANGE = 55.0..300.0
        FLOOR_DB = 80.0

        # Band edges (Hz) of the three onset bands: low (kicks, bass), mid,
        # and high (hats).
        BANDS = [0.0...150.0, 150.0...2000.0, 2000.0..].freeze

        # Frames processed per chunk (memory for one chunk of windows).
        CHUNK = 256

        attr_reader :sample_rate, :logmel, :mfcc, :chroma, :bass_chroma, :energy, :band_flux, :count

        # Computes the frame features of +mono+ (a Numo array) at
        # +sample_rate+.
        def initialize(mono, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          compute(Numo::DFloat.cast(mono))
        end

        # Frames per second.
        def fps
          @sample_rate / HOP
        end

        # The time in seconds of (fractional) frame index +i+.
        def seconds(i)
          i / fps
        end

        # The onset envelope used for tempo and beats: the three bands'
        # envelopes (see #band_onsets) averaged with equal weight.
        def onset
          @onset ||= band_onsets.sum / band_onsets.length
        end

        # Per-band onset envelopes: each band's flux minus its 1 s moving
        # average, half-wave rectified, at unit standard deviation.
        def band_onsets
          @band_onsets ||= @band_flux.map { |b| Frames.onset_envelope(b, fps.round) }
        end

        # A weighted sum of the band onset envelopes, for choosing a beat
        # grid's phase (4:1:1 by default, so kicks beat offbeat hats).
        def phase_onset(weights = [4, 1, 1])
          band_onsets.zip(weights).sum { |b, w| b * w }
        end

        # Flux minus its +width+-frame moving average, rectified, scaled to
        # unit standard deviation.
        def self.onset_envelope(flux, width)
          o = (flux - moving_average(flux, width)).clip(0, nil)
          sd = o.stddev
          sd > 0 ? o / sd : o
        end

        # Centered moving average over +width+ values (fewer at the ends).
        def self.moving_average(x, width)
          n = x.size
          sums = Numo::DFloat.zeros(n + 1)
          sums[1..] = x.cumsum
          h = width / 2
          idx = Numo::Int64.new(n).seq
          lo = (idx - h).clip(0, n)
          hi = (idx + h + 1).clip(0, n)
          (sums[hi] - sums[lo]) / (hi - lo)
        end

        private

        def compute(mono)
          n = 1 + mono.length / HOP
          x = Numo::DFloat.zeros(mono.length + N_FFT)
          x[(N_FFT / 2)...(N_FFT / 2 + mono.length)] = mono

          win = 0.5 - 0.5 * Numo::NMath.cos(2 * Math::PI * Numo::DFloat.new(N_FFT).seq / N_FFT)
          fb = mel_filterbank
          cm = Numo::DFloat.hstack([chroma_map(CHROMA_RANGE), chroma_map(BASS_CHROMA_RANGE)])

          mel = Numo::DFloat.zeros(n, N_MEL)
          chroma = Numo::DFloat.zeros(n, 24)
          energy = Numo::DFloat.zeros(n)
          mag = Numo::DFloat.zeros(CHUNK, N_FFT / 2 + 1)

          0.step(n - 1, CHUNK) do |start|
            count = [CHUNK, n - start].min
            count.times do |j|
              i = (start + j) * HOP
              mag[j, true] = Numo::Pocketfft.rfft(x[i...(i + N_FFT)] * win).abs
            end
            m = count == CHUNK ? mag : mag[0...count, true]
            power = m**2
            rows = start...(start + count)
            mel[rows, true] = power.dot(fb)
            chroma[rows, true] = m.dot(cm)
            energy[rows] = power.sum(axis: 1)
          end

          logmel = 10 * Numo::NMath.log10(mel + 1e-12)
          logmel = logmel.clip(logmel.max - FLOOR_DB, nil)
          @logmel = logmel
          @mfcc = logmel.dot(dct_matrix) / N_MEL
          @chroma = chroma[true, 0...12].dup
          @bass_chroma = chroma[true, 12...24].dup
          @energy = 10 * Numo::NMath.log10(energy + 1e-12)
          @count = n

          diff = Numo::DFloat.zeros(n, N_MEL)
          diff[1..-1, true] = logmel[1..-1, true] - logmel[0...-1, true] if n > 1
          diff[0, true] = logmel[0, true] - logmel.min
          diff = diff.clip(0, nil)
          @band_flux = BANDS.map { |range|
            idx = @mel_centers.each_index.select { |i| range.cover?(@mel_centers[i]) }
            diff[true, idx].mean(axis: 1)
          }
        end

        def bin_freqs
          Numo::DFloat.new(N_FFT / 2 + 1).seq * @sample_rate / N_FFT
        end

        def self.hz_to_mel(f) = 2595.0 * Math.log10(1 + f / 700.0)
        def self.mel_to_hz(m) = 700.0 * (10**(m / 2595.0) - 1)

        # Triangular mel filterbank (bins x N_MEL); also sets @mel_centers.
        def mel_filterbank
          fmax = [MEL_RANGE.end, @sample_rate / 2].min
          mels = Numo::DFloat.linspace(Frames.hz_to_mel(MEL_RANGE.begin), Frames.hz_to_mel(fmax), N_MEL + 2).to_a
          edges = mels.map { |m| Frames.mel_to_hz(m) }
          @mel_centers = edges[1..N_MEL]
          f = bin_freqs.to_a
          fb = Numo::DFloat.zeros(f.length, N_MEL)
          N_MEL.times do |b|
            lo, c, hi = edges[b], edges[b + 1], edges[b + 2]
            f.each_with_index do |fr, k|
              next if fr <= lo || fr >= hi
              fb[k, b] = fr < c ? (fr - lo) / (c - lo) : (hi - fr) / (hi - c)
            end
          end
          fb
        end

        # Chroma map (bins x 12) for bins in +range+ (Hz).
        def chroma_map(range)
          f = bin_freqs.to_a
          m = Numo::DFloat.zeros(f.length, 12)
          f.each_with_index do |fr, k|
            next unless range.cover?(fr)
            midi = 69 + 12 * Math.log2(fr / 440.0)
            lo = midi.floor
            w = midi - lo
            m[k, lo % 12] += 1 - w
            m[k, (lo + 1) % 12] += w
          end
          m
        end

        # DCT-II matrix (N_MEL x N_MFCC).
        def dct_matrix
          d = Numo::DFloat.zeros(N_MEL, N_MFCC)
          N_MEL.times { |i| N_MFCC.times { |k| d[i, k] = Math.cos(Math::PI * k * (i + 0.5) / N_MEL) } }
          d
        end
      end
    end
  end
end
