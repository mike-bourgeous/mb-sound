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
    # will have a DC component of 1.0, and so that a sine wave from -1.0 to 1.0
    # in a 1D FFT on an exact bin frequency will have positive and negative
    # frequency bin values that sum to 1.0 (or a bin value of 1.0 for a real
    # FFT).  The IFFT methods undo the normalization to restore the original
    # signal.
    #
    # Parameters to all methods may be a Numo::NArray, a Tone, an Array
    # thereof, or a numeric Array.  See IOMethods#any_sound_to_array.
    module FFTMethods
      # Returns the normalized complex FFT of the given data (e.g.
      # Numo::NArray, Tone, or Array thereof).
      #
      # See the MB::Sound::FFTMethods module documentation for more
      # information.
      def fft(data)
        case data
        when Numo::NArray
          case data.ndim
          when 1
            (Numo::Pocketfft.fft(data).inplace / data.length).not_inplace!

          when 2
            (Numo::Pocketfft.fft2(data).inplace / data.length).not_inplace!

          else
            (Numo::Pocketfft.fftn(data).inplace / data.length).not_inplace!
          end

        when Array
          any_sound_to_array(data).map { |v|
            fft(v)
          }

        else
          fft(any_sound_to_array(data)[0])
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
        case data
        when Numo::NArray
          case data.ndim
          when 1
            (Numo::Pocketfft.ifft(data).inplace * data.length).not_inplace!

          when 2
            (Numo::Pocketfft.ifft2(data).inplace * data.length).not_inplace!

          else
            (Numo::Pocketfft.ifftn(data).inplace * data.length).not_inplace!
          end

        when Array
          any_sound_to_array(data).map { |v|
            ifft(v)
          }

        else
          ifft(any_sound_to_array(data)[0])
        end
      end

      # Returns the normalized complex FFT of the given data (e.g.
      # Numo::NArray, Tone, or Array thereof).
      #
      # See the MB::Sound::FFTMethods module documentation for more
      # information.
      def real_fft(data)
        case data
        when Numo::NArray
          case data.ndim
          when 1
            Numo::Pocketfft.rfft(data)

          when 2
            Numo::Pocketfft.rfft2(data)

          else
            Numo::Pocketfft.rfftn(data)
          end

        when Array
          any_sound_to_array(data).map { |v|
            real_fft(v)
          }

        else
          real_fft(any_sound_to_array(data)[0])
        end
      end

      def real_ifft(data, odd_length: false)
        if odd_length
          # TODO: support more dimensions?
          raise "Odd lengths can only be inverted for 1-dimensional data" unless data.ndim == 1
          data = generate_negative_freqs(data, odd_length: true)
        end

        case data
        when Numo::NArray
          case data.ndim
          when 1
            Numo::Pocketfft.irfft(data)

          when 2
            Numo::Pocketfft.irfft2(data)

          else
            Numo::Pocketfft.irfftn(data)
          end

        when Array
          any_sound_to_array(data).map { |v|
            real_ifft(v)
          }

        else
          real_ifft(any_sound_to_array(data)[0])
        end
      end
    end
  end
end
