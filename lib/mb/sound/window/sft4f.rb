require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Salvatore 1988 4-term fast decay flat-top window as described in
      # Heinzel 2002.
      class SFT4F < Window
        include CosineSum

        def initialize(length)
          @coefficients = [0.21706, -0.42103, 0.28294, -0.07897]
          super(length, (length * 0.75).round)
        end
      end
    end
  end
end
