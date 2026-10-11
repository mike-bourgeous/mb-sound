module MB
  module Sound
    module Plot
      # Coordinate systems turn scaled data into positions in the unit
      # square (u right, v up), which renderers stretch over a panel's plot
      # area.
      module Coord
        # x and y scales straight to u and v.
        class Cartesian
          attr_reader :x, :y

          def initialize(x:, y:)
            @x = x
            @y = y
          end

          # [u, v] (Numo::DFloats) for data arrays +xs+ and +ys+.
          def project(xs, ys)
            [@x.map(xs), @y.map(ys)]
          end

          # A copy with other scales.
          def with(x: @x, y: @y)
            self.class.new(x: x, y: y)
          end

          def polar?
            false
          end
        end

        # x is the angle (its scale's domain is one turn, counterclockwise
        # from the right) and y the radius (0 at the center, 1 at the edge
        # of a circle inscribed in the plot area).  Renderers draw rings and
        # spokes instead of axes.
        class Polar < Cartesian
          def project(xs, ys)
            theta = @x.map(xs) * (2 * Math::PI)
            r = @y.map(ys) * 0.5
            [Numo::NMath.cos(theta) * r + 0.5, Numo::NMath.sin(theta) * r + 0.5]
          end

          def polar?
            true
          end
        end
      end
    end
  end
end
