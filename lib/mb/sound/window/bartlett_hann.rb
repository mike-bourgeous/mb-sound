module MB
  module Sound
    class Window
      class BartlettHann < Window
        def initialize(length)
          super(length, (length * 0.75).round)
        end

        private

        def gen_pre_window(length)
          n = length # Use length - 1 for "symmetric" version
          window = length.times.map { |j|
            w = (j.to_f / n - 0.5)
            0.62 - 0.48 * w.abs + 0.38 * Math.cos(Math::PI * 2.0 * w)
          }

          MB::M.array_to_narray(window)
        end
      end
    end
  end
end
