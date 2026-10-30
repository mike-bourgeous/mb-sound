module MB
  module Sound
    module Analysis
      # Short-time Fourier transform magnitudes, computed a chunk of frames
      # at a time so a long song's spectrogram is never kept whole (the
      # shared front end of Structure::Frames, Analysis::Chroma, and
      # Analysis::Spectrum).
      #
      # Frames are centered on multiples of +hop+ (frame i at i * hop
      # samples) with half a window of silence before the start and after
      # the end, so a note on sample 0 is in frame 0; there are
      # 1 + length / hop frames.  The window is a periodic Hann.
      module STFT
        # Frames processed per chunk (memory for one chunk of windows).
        CHUNK = 256

        # The number of frames of a +length+-sample signal at +hop+.
        def self.count(length, hop)
          1 + length / hop
        end

        # A periodic Hann window of +n+ samples (a Numo::DFloat).
        def self.hann(n)
          0.5 - 0.5 * Numo::NMath.cos(2 * Math::PI * Numo::DFloat.new(n).seq / n)
        end

        # The frequency in Hz of each of the n_fft / 2 + 1 bins.
        def self.bin_freqs(n_fft, sample_rate)
          Numo::DFloat.new(n_fft / 2 + 1).seq * sample_rate.to_f / n_fft
        end

        # Yields (+rows+, +mag+) for each chunk of frames of +mono+ (a Numo
        # array): +rows+ the Range of frame indices, +mag+ a DFloat of
        # rows.size x (n_fft / 2 + 1) magnitudes (a buffer reused between
        # chunks: copy what you keep).  Returns the frame count.
        def self.each_chunk(mono, n_fft:, hop:, chunk: CHUNK)
          mono = Numo::DFloat.cast(mono)
          n = count(mono.length, hop)
          x = Numo::DFloat.zeros(mono.length + n_fft)
          x[(n_fft / 2)...(n_fft / 2 + mono.length)] = mono
          win = hann(n_fft)
          mag = Numo::DFloat.zeros(chunk, n_fft / 2 + 1)

          0.step(n - 1, chunk) do |start|
            rows = [chunk, n - start].min
            rows.times do |j|
              i = (start + j) * hop
              mag[j, true] = Numo::Pocketfft.rfft(x[i...(i + n_fft)] * win).abs
            end
            yield start...(start + rows), rows == chunk ? mag : mag[0...rows, true]
          end
          n
        end
      end
    end
  end
end
