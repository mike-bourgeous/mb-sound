module MB
  module Sound
    class Window
      # A rectangular window function that always has a value of 1.0 and an
      # overlap of 3/4ths the length.
      class Rectangular < Window
        def initialize(length)
          super(length, (length * 0.75).round)
        end

        private

        def gen_pre_window(length)
          Numo::SFloat.ones(length)
        end
      end
    end
  end
end
