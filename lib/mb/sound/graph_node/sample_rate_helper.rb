module MB
  module Sound
    module GraphNode
      # Provides basic support for recursive sample rate changes on a node
      # chain.  Classes that want to support sample rate changes after
      # construction may start by including this module, then overriding the
      # sample_rate= method as needed (e.g. to recalculate durations or
      # counters that are sample-rate-specific).
      #
      # Only include this module if changing sample rates is supported by the
      # class.
      #
      # Example:
      #     class Z
      #       include SampleRateHelper
      #
      #       def sample_rate=(new_rate)
      #         @duration = @duration * new_rate / @sample_rate
      #         super
      #       end
      module SampleRateHelper
        # Raised when given a sample rate that is the wrong type or is not a
        # positive number.
        class SampleRateRangeError < ArgumentError
          def initialize(msg = nil)
            super(['Sample rate must be a positive Float, Rational, or Integer', msg].compact.join(': '))
          end
        end

        # Raised when a source does not support changing its sample rate.
        class SampleRateSupportError < TypeError
          def initialize(source)
            super("Source #{source} does not support changing sample rate")
          end
        end

        # The sample rate of this node.
        attr_reader :sample_rate

        # Recursively ets the sample rate of this node and all upstream nodes
        # (unless a node is a sample rate boundary, e.g. the Resample node) to
        # +new_rate+, even if the new sample rate is the same as the existing
        # sample rate.
        #
        # The #at_rate alias returns self for method chaining.
        def sample_rate=(new_rate)
          case new_rate
          when Rational, Integer, Float
            raise SampleRateRangeError, "got #{new_rate.inspect}" unless new_rate.finite? && new_rate > 0

            new_rate = new_rate.to_f

          else
            raise SampleRateRangeError, "got #{new_rate.inspect}"
          end

          # Check support on all sources first to minimize damage done.
          # Otherwise some sample rates could be changed but not others if
          # there is partial support.
          sources.each do |_, src|
            # Skip any strings or numerics listed as sources
            # TODO: only allow GraphNodes as sources?
            next unless src.respond_to?(:sample_rate)

            unless src.respond_to?(:sample_rate=)
              raise SampleRateSupportError.new(src)
            end
          end

          sources.each do |_, src|
            next unless src.respond_to?(:sample_rate)
            src.send(:sample_rate=, new_rate)
          end

          @sample_rate = new_rate

          self

        rescue => e
          raise e, "#{e.message} [on #{self}]"
        end
        alias at_rate sample_rate=

        protected

        # Checks the sample rate of the +other+ node, either setting this
        # node's sample rate to match, or setting the +other+ node's sample
        # rate to match.  Raises an error if the +other+ node does not support
        # changing sample rates and the rate does not match.
        def check_rate(other, idx_or_name = sources&.length)
          if other.respond_to?(:sample_rate)
            @sample_rate ||= other.sample_rate
            if other.sample_rate != @sample_rate
              if other.respond_to?(:sample_rate=)
                other.sample_rate = @sample_rate
              elsif other.respond_to?(:at_rate)
                other.at_rate(@sample_rate)
              else
                raise "Source #{idx_or_name}/#{other} sample rate is #{other.sample_rate}; expected #{@sample_rate}"
              end
            end
          end
        end
      end
    end
  end
end
