require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Hann or Hanning raised cosine window, applied after processing
      # instead of before.
      class HannPost < Window
        include CosineSum

        def initialize(length)
          @rectwin = MB::Sound::Window::Rectangular.new(length)

          @coefficients = [0.5, -0.5]
          super(length, (length * 0.75).round)

          @post_window = @pre_window
          @pre_window = @rectwin.pre_window
        end
      end
    end
  end
end
