module MB
  module Sound
    class Window
      # A triangular window function that ramps from 0 to 1 at the given midpoint
      # (in fractional samples from 0 to length - 1, so 2.5 is the natural
      # midpoint of a length 6 window), then from 1 to 0 until the window end.
      # The first and last samples will be 0 if +zero+ is true (default is
      # false).  This is the same thing as a Bartlett window if +midpoint+ is at
      # the default and +zero+ is true.
      class Triangular < Window
        attr_reader :midpoint

        def initialize(length, midpoint: nil, zero: false)
          @midpoint = midpoint || (length - 1) * 0.5
          @zero = zero
          super(length, (length * 0.75).round)
        end

        private

        def gen_pre_window(length)
          up = line(@zero ? 0 : -1, 0, @midpoint, 1, 0, @midpoint.floor)
          down = line(@midpoint, 1, length - (@zero ? 1 : 0), 0, @midpoint.floor + 1, length - 1)

          if up.length == 0
            window = down
          elsif down.length == 0
            window = up
          else
            window = up.concatenate(down)
          end
        end

        # Returns an array of y-value samples of the line defined by (x1,
        # y1)..(x2, y2) starting from x = xmin and ending at x = xmax,
        # incrementing by 1.  xmin and xmax should be integers.
        def line(x1, y1, x2, y2, xmin, xmax)
          m = (y2.to_f - y1.to_f) / (x2.to_f - x1.to_f)
          b = y1 - m * x1

          samples = (xmax - xmin + 1).to_i
          arr = Numo::SFloat.new(samples).allocate
          samples.times do |x|
            arr[x] = m * (x + xmin) + b
          end

          arr
        end
      end
    end
  end
end
