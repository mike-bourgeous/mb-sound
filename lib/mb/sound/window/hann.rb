require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Hann or Hanning raised cosine window.
      class Hann < Window
        include CosineSum

        def initialize(length)
          @coefficients = [0.5, -0.5]
          super(length, (length * 0.75).round)
        end
      end
    end
  end
end
