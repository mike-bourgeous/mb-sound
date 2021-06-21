# TODO: load FFTW if it's present
require 'numo/pocketfft'

module MB
  module Sound
    # Command-line methods for performing forward and inverse FFTs.  MB::Sound
    # extends itself with this module (e.g. use MB::Sound.fft to call the #fft
    # method).
    #
    # Multiple dimensions are supported, but not as thoroughly tested, as the
    # majority of what we want to do with audio uses a single dimensional FFT.
    #
    # Return values are normalized so that an array filled with the value 1.0
    # will have a DC component of 2.0, and so that a sine wave from -1.0 to 1.0
    # in a 1D FFT on an exact bin frequency will have a bin magnitude of 1.0.
    # The IFFT methods undo this normalization to restore the original signal.
    #
    # Parameters to all methods may be a Numo::NArray, a Tone, an Array
    # thereof, or a numeric Array.  See IOMethods#any_sound_to_array.
    module FFTMethods
      module PocketfftMethods
        # Returns the normalized complex FFT of the given data (e.g.
        # Numo::NArray, Tone, or Array thereof).
        #
        # See the MB::Sound::FFTMethods module documentation for more
        # information.
        def fft(data)
          data = convert_sound_to_narray(data) unless data.is_a?(Numo::NArray)

          case data
          when Numo::NArray
            case data.ndim
            when 1
              (Numo::Pocketfft.fft(data).inplace * (2.0 / data.length)).not_inplace!

            when 2
              (Numo::Pocketfft.fft2(data).inplace * (2.0 / data.length)).not_inplace!

            else
              (Numo::Pocketfft.fftn(data).inplace * (2.0 / data.length)).not_inplace!
            end

          when Array
            data.map { |v| fft(v) }

          else
            raise "Unsupported data type: #{data.class}"
          end
        end

        # Returns the inverse normalized complex FFT of the given
        # frequency-domain data (e.g. Numo::NArray, Tone, or Array thereof).
        # This method compensates for the normalization performed by
        # FFTMethods#fft.
        #
        # See the MB::Sound::FFTMethods module documentation for more
        # information.
        def ifft(data)
          data = convert_sound_to_narray(data) unless data.is_a?(Numo::NArray)

          case data
          when Numo::NArray
            case data.ndim
            when 1
              (Numo::Pocketfft.ifft(data).inplace * (data.length / 2.0)).not_inplace!

            when 2
              (Numo::Pocketfft.ifft2(data).inplace * (data.length / 2.0)).not_inplace!

            else
              (Numo::Pocketfft.ifftn(data).inplace * (data.length / 2.0)).not_inplace!
            end

          when Array
            data.map { |v| ifft(v) }

          else
            raise "Unsupported data type: #{data.class}"
          end
        end

        # Returns only the positive frequencies of the normalized complex FFT
        # of the given real data (e.g. Numo::SFloat/DFloat, Tone, or Array
        # thereof).
        #
        # See the MB::Sound::FFTMethods module documentation for more
        # information.
        def real_fft(data)
          data = convert_sound_to_narray(data) unless data.is_a?(Numo::NArray)

          case data
          when Numo::NArray
            case data.ndim
            when 1
              (Numo::Pocketfft.rfft(data).inplace * (2.0 / data.length)).not_inplace!

            when 2
              (Numo::Pocketfft.rfft2(data).inplace * (2.0 / data.length)).not_inplace!

            else
              (Numo::Pocketfft.rfftn(data).inplace * (2.0 / data.length)).not_inplace!
            end

          when Array
            data.map { |v| real_fft(v) }

          else
            raise "Unsupported data type: #{data.class}"
          end
        end

        # Returns the real component of the inverse normalized FFT of the given
        # positive-frequencies-only frequency-domain data (e.g. Numo::NArray,
        # Tone, or Array thereof).  This method compensates for the normalization
        # performed by FFTMethods#real_fft.
        #
        # See the MB::Sound::FFTMethods module documentation for more
        # information.
        def real_ifft(data, odd_length: false)
          data = convert_sound_to_narray(data) unless data.is_a?(Numo::NArray)

          case data
          when Numo::NArray
            if odd_length
              # TODO: support more dimensions?
              data = generate_negative_freqs(data, odd_length: true)
              return ifft(data).real
            end

            orig_length = data.shape[0..-2].reduce(1, &:*) * (data.shape[-1] - 1) * 2

            case data.ndim
            when 1
              (Numo::Pocketfft.irfft(data).inplace * (orig_length / 2.0)).not_inplace!

            when 2
              (Numo::Pocketfft.irfft2(data).inplace * (orig_length / 2.0)).not_inplace!

            else
              (Numo::Pocketfft.irfftn(data).inplace * (orig_length / 2.0)).not_inplace!
            end

          when Array
            data.map { |v| real_ifft(v) }

          else
            raise "Unsupported data type: #{data.class}"
          end
        end
      end

      # Computes the DFT of the given +narray+, shifts it so the DC coefficient is
      # in the middle, and keeps at most +bins+ bins on either side.  If +db+ is
      # true, the values will be converted to decibels.  Useful for visualizing
      # window functions.
      def trunc_fft(narray, bins, db = false)
        dft = fft(narray)
        mid = dft.size * 0.5
        min = [0, (mid - bins).to_i].max
        max = [dft.size - 1, (mid + bins).to_i].min
        dft = MB::M.rol(dft, mid.to_i)
        dft = dft[min..max]
        # TODO: Remove to_a conversion step if possible
        db ? MB::M.array_to_narray(dft.to_a.map { |v|
          db = v.to_db
          db = [-60, db].max unless db.nan?
          db
        }) : dft
      end

      # Generates negative frequencies from the given FFT data with only
      # positive frequencies.  This is not required if you use the #real_fft
      # and #real_ifft methods.
      def generate_negative_freqs(data, odd_length: false)
        raise NotImplementedError, 'Only one dimension supported at this time' if data.ndim != 1

        # TODO: Use inplace! where possible if it speeds things up
        neg = data[1..(odd_length ? -1 : -2)].reverse
        data.concatenate(neg.conj)
      end

      # Converts the given +data+ to a complex analytic signal with real and
      # imaginary components (the real component should match the original if the
      # original signal was real).
      #
      # Note that if the data is not periodic, the imaginary component produced
      # near the endpoints may not match what would be produced for the same region
      # when in the middle of the data window.
      #
      # See #positive_freqs and #generate_negative_freqs
      def analytic_signal(data)
        data = convert_sound_to_narray(data)
        if data.is_a?(Array)
          return data.map { |v| analytic_signal(v) }
        end

        full_dft = fft(data).inplace

        # See https://www.gaussianwaves.com/2017/04/analytic-signal-hilbert-transform-and-fft/
        # See https://ccrma.stanford.edu/~jos/mdft/Analytic_Signals_Hilbert_Transform.html
        midpoint = full_dft.size / 2
        end_pos = midpoint - (data.length.odd? ? 0 : 1)
        end_neg = midpoint + 1

        full_dft[1..end_pos] += full_dft[end_neg..-1].reverse.conj
        full_dft[end_neg..-1] = 0

        ifft(full_dft).not_inplace!
      end

      # TODO: conditionally use FFTW if present?
      if defined?(Numo::Pocketfft)
        include PocketfftMethods
      else
        raise 'Unable to find an FFT gem'
      end
    end
  end
end
