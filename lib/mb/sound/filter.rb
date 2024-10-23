module MB
  module Sound
    # Template/base class for filters showing the methods filter objects should
    # implement.  For implementation examples see MB::Sound::Filter::Biquad or
    # MB::Sound::Filter::FilterChain.
    class Filter
      # Should accept either a Float or a Numo::NArray (e.g. Numo::SFloat) and
      # return the single sample or array of samples as processed through the
      # filter.  Subclasses may also accept Complex values; check their
      # documentation.
      def process(value)
        raise NotImplementedError, 'Subclasses must override #process'
      end

      # Should accept a Float (or maybe a Complex) and return the result of
      # sending that value through the filter.
      def process_one(value)
        process(Numo::SFloat[value])[0]
      end

      # If implemented, should reset filter to the given steady-state input.
      # Must return the steady-state output for the given input.
      def reset(value = 0)
        raise NotImplementedError, 'Subclasses must override #reset if supported'
      end

      # TODO: either make this make sense or remove it
      def weighted_process(data, strength)
        raise NotImplementedError, 'Subclasses must override #weighted_process if supported'
      end

      # Processes +samples+ both forward and backward, resulting in a higher
      # order filter with no phase distortion.  Resets the state of the filter,
      # so this cannot be mixed with the normal #process function.
      #
      # If +samples+ is an in-place Numo::NArray, then the processing may be done
      # in-place, depending on the filter.
      def double_process(samples)
        reset(samples[0])

        # First prime the state
        process(samples.reverse)

        # Process forward and backward
        process(process(samples).reverse).reverse
      end

      # Appends another filter after this filter, returning a filter chain.
      def chain(next_filter)
        FilterChain.new(self, next_filter)
      end

      # Most filters cannot contain other filters, so return false unless this
      # is the same exact filter.  See FilterChain#has_filter?.
      def has_filter?(filter)
        self.equal?(filter)
      end

      # Generates a time domain impulse response for the filter by processing a
      # single 1 followed by zeros.  This resets the state of the filter.
      #
      # TODO: compensate for the delay in FIR filters?
      def impulse_response(count = 500)
        reset(0)
        data = Numo::SFloat.zeros(count)
        data[0] = 1
        process(data).tap { reset(0) }
      end

      # Returns a complex frequency-domain response, with +count+ evenly spaced
      # samples from 0 to pi.  The filter subclass must implement #response.
      def frequency_response(count = 500)
        raise 'This filter does not support returning the frequency domain response' unless respond_to?(:response)
        response(Numo::SFloat.linspace(0, Math::PI, count))
      end

      # Wraps a +source+ providing a :sample method with this filter.
      def wrap(source, in_place: true)
        SampleWrapper.new(self, source, in_place: in_place)
      end
    end
  end
end

require_relative 'filter/sample_wrapper'
require_relative 'filter/gain'
require_relative 'filter/biquad'
require_relative 'filter/first_order'
require_relative 'filter/cookbook'
require_relative 'filter/filter_chain'
require_relative 'filter/filter_bank'
require_relative 'filter/filter_sum'
require_relative 'filter/butterworth'
require_relative 'filter/simple_envelope_follower'
require_relative 'filter/fir'
require_relative 'filter/linear_follower'
require_relative 'filter/delay'
require_relative 'filter/smoothstep'
require_relative 'filter/hilbert_iir'
