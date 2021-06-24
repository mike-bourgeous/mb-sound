require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Hann or Hanning raised cosine window, used for both pre and post
      # windows.  The pre window is half the width of the post window, centered
      # and zero-padded.
      class PadDoubleHann < Window
        def initialize(length)
          @coefficients = [0.5, -0.5]
          super(length, length - 1) # fixme: is there a way to have a hop larger than one sample?
        end

        def overlap_gain
          super / 1.8488263734946286 # empirically measured
        end

        private

        def gen_pre_window(length)
          w = CosineSum.generate_window(length / 2, @coefficients)
          MB::M.zpad(w, length, alignment: 0.5)
        end

        def gen_post_window(length)
          CosineSum.generate_window(length, @coefficients)
        end
      end
    end
  end
end
