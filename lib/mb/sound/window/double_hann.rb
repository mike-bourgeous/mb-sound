require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Hann or Hanning raised cosine window, used for both pre and post
      # windows.
      class DoubleHann < Window
        include CosineSum

        def initialize(length)
          @coefficients = [0.5, -0.5]
          super(length, (length * 0.875).round)
        end

        def overlap_gain
          super / 1.5
        end

        private

        def gen_post_window(length)
          gen_pre_window(length)
        end
      end
    end
  end
end
