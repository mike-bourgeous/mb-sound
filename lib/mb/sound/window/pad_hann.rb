require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # A Hann window zero-padded to twice its starting width.
      class PadHann < Window
        # Initializes a padded Hann pre-window of width +length+/2, zero-padded
        # (centered) to +length+.
        def initialize(length)
          @coefficients = [0.5, -0.5]
          super(length, (length * (7.0 / 8.0)).round)
        end

        private

        def gen_pre_window(length)
          w = CosineSum.generate_window(length / 2, @coefficients)
          MB::M.zpad(w, length, alignment: 0.5)
        end
      end
    end
  end
end
