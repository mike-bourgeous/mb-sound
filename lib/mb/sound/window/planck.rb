module MB
  module Sound
    class Window
      # The Planck-taper window, with a flat middle region and an infinitely
      # differentiable rise and fall on the edges.
      #
      # See https://en.wikipedia.org/wiki/Window_function#Planck-taper_window
      class Planck < Window
        attr_reader :taper

        # Initializes a Planck-taper window function with the given +length+, in
        # samples, and the given +taper+ on each end, also in samples.  The
        # default +taper+ is [TODO] one eighth of the length.
        def initialize(length, taper: nil)
          @taper = taper || length / 2
          @tf2 = 2.0 * @taper.to_f / length
          super(length, length - @taper / 2)
        end

        private

        def gen_pre_window(length)
          w = Numo::SFloat.zeros(length)
          length.times do |n|
            frac = 2.0 * n / length - 1
            case
            when n < taper
              zp = @tf2 * (1.0 / (1.0 + frac) + 1.0 / (1.0 - @tf2 + frac))
              w[n] = 1.0 / (Math.exp(zp) + 1.0)
            when n > length - taper
              zm = @tf2 * (1.0 / (1.0 - frac) + 1.0 / (1.0 - @tf2 - frac))
              w[n] = 1.0 / (Math.exp(zm) + 1.0)
            else
              w[n] = 1.0
            end

            # XXX w[n] = Math.sqrt(w[n]) # XXX
          end

          w
        end

        #def gen_post_window(length)
        #  gen_pre_window(length)
        #end
      end
    end
  end
end
