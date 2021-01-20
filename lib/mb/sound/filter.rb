module MB
  module Sound
    # Template/base class for filters showing the methods filter objects should
    # implement.  For implementation examples see MB::Sound::Filter::Biquad or
    # MB::Sound::Filter::FilterChain.
    class Filter
      # Should accept either a Float or a Numo::NArray (e.g. Numo::SFloat) and
      # return the single sample or array of samples as processed through the
      # filter.
      def process(value)
        raise NotImplementedError, 'Subclasses must override #process'
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
    end
  end
end

require_relative 'filter/gain'
require_relative 'filter/biquad'
require_relative 'filter/first_order'
require_relative 'filter/cookbook'
require_relative 'filter/filter_chain'
require_relative 'filter/filter_bank'
require_relative 'filter/filter_sum'
require_relative 'filter/butterworth'
require_relative 'filter/envelope_follower'
require_relative 'filter/fir'
