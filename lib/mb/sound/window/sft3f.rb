require_relative 'cosine_sum'

module MB
  module Sound
    class Window
      # The Salvatore 1988 3-term fast decay flat-top window as described in
      # Heinzel 2002.
      class SFT3F < Window
        include CosineSum

        def initialize(length)
          @coefficients = [0.26526, -0.5, 0.23474]
          super(length, (length * 0.75).round)
        end
      end
    end
  end
end
