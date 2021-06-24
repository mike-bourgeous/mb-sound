module MB
  module Sound
    class Window
      # The HFT116D flat-top window from Heinzel 2002.
      class HFT116D < Window
        include CosineSum

        def initialize(length)
          @coefficients = [1, -1.9575375, 1.4780705, -0.6367431, 0.1228389, -0.0066288]
          super(length, (length * 0.875).round)
        end
      end
    end
  end
end
