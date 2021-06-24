module MB
  module Sound
    class Window
      # A generic summed cosine window (e.g. Hann, Hamming, flat-top).  This
      # class is usually not used directly, but rather inherited by specific
      # cosine sum window classes.
      module CosineSum
        # Window generation function for use outside of a Window class.  See
        # #coefficients.
        def self.generate_window(length, coefficients)
          n = length # Set n to length - 1 for "symmetric" version
          w = length.times.map { |j|
            coefficients.each_with_index.map { |c, idx|
              c * Math.cos(idx * Math::PI * 2 * j / n)
            }.sum
          }

          MB::M.array_to_narray(w)
        end

        # Cosine coefficients, starting with DC (so [0] is the constant offset,
        # [1] is the fundamental, [2] is twice the frequency of the fundamental,
        # etc).
        attr_reader :coefficients

        private

        def gen_pre_window(length)
          CosineSum.generate_window(length, coefficients)
        end
      end
    end
  end
end
