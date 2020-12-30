module MB
  module Sound
    class Filter
      # Implements low- and high-pass filters with a maximally flat Butterworth
      # response.
      class Butterworth < FilterChain
        attr_reader :sample_rate, :center_frequency

        def initialize(filter_type, order, f_samp, f_center)
          raise 'Invalid filter type' unless filter_type == :highpass || filter_type == :lowpass

          @sample_rate = f_samp
          @center_frequency = f_center

          filters = Butterworth.qvalues(order).map { |q|
            Sound::Filter::Cookbook.new(filter_type, f_samp, f_center, quality: q)
          }

          if order.odd?
            ft1p = filter_type == :highpass ? :highpass : :lowpass
            filters << Sound::Filter::FirstOrder.new(ft1p, f_samp, f_center)
          end

          super(*filters)
        end

        def center_frequency=(f_center)
          @center_frequency = f_center

          @filters.each do |f|
            case f
            when Sound::Filter::FirstOrder
              f.set_parameters(f.filter_type, @sample_rate, @center_frequency)

            when Sound::Filter::Cookbook
              f.set_parameters(f.filter_type, @sample_rate, @center_frequency, quality: f.quality)

            else
              raise "BUG: unexpected filter type #{f.class} in Butterworth filter"
            end
          end
        end

        # Returns an array containing the Q values of cascaded biquads needed to
        # produce a Butterworth filter of the given order (omits first-order pole
        # for odd orders).
        #
        # See https://www.earlevel.com/main/2016/09/29/cascading-filters/
        def self.qvalues(order)
          poles(order).first(order / 2).map { |p| 1.0 / (2.0 * Math.cos(Math::PI - p)) }
        end

        # Returns an array containing the angles of the s-plane poles of a
        # Butterworth filter of the given order.
        def self.poles(order)
          spacing = Math::PI / order
          extent = spacing * (order - 1)
          start = Math::PI - 0.5 * extent
          poles = Array.new(order)
          for o in 0...order
            poles[o] = start + o * spacing
          end
          poles
        end
      end
    end
  end
end
