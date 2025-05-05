module MB
  module Sound
    module GraphNode
      # This graph node converts from one sample rate to another.  The upstream
      # sample rate is detected from the source node.
      #
      # TODO: should this be a Filter, and/or should we add a Filter variant?
      class Resample
        include GraphNode
        include BufferHelper

        # Resampling modes supported by the class (pass to constructor's
        # +:mode+ parameter).
        #
        # Note that some modes may add several buffers worth of latency.
        MODES = [
          :ruby_zoh,
          :ruby_linear,
          :libsamplerate_zoh,
          :libsamplerate_linear,
          :libsamplerate_fastest,
          :libsamplerate_best,
        ].freeze

        # The default mode if no mode is given to the constructor.
        DEFAULT_MODE = :libsamplerate_best

        # The output sample rate.
        attr_reader :sample_rate

        # The output sample rate ratio (output rate divided by input rate).
        attr_reader :ratio

        # The input sample rate ratio (input rate divided by output rate)
        attr_reader :inv_ratio

        # Creates a resampling graph node with the given +:upstream+ node and
        # +:sample_rate+.  The +:mode+ parameter may be one of the supported
        # MODES listed above to change the resampling algorithm.  The default
        # is libsamplerate's best sinc converter.
        def initialize(upstream:, sample_rate:, mode: DEFAULT_MODE)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream must respond to :sample_rate' unless upstream.respond_to?(:sample_rate)

          raise "Unsupported mode #{mode.inspect}" unless MODES.include?(mode)
          @mode = mode

          @upstream = upstream
          @sample_rate = sample_rate.to_f
          @inv_ratio = upstream.sample_rate.to_f / @sample_rate
          @ratio = @sample_rate / upstream.sample_rate.to_f
          @error = 0
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Returns +count+ samples at the new sample rate, while requesting
        # sufficient samples from the upstream node to fulfill the request.
        def sample(count)
          case @mode
          when :ruby_zoh, :ruby_linear
            sample_ruby(count, @mode)

          when :libsamplerate_best, :libsamplerate_fastest, :libsamplerate_zoh, :libsamplerate_linear
            @fast_resample ||= MB::Sound::FastResample.new(@ratio, @mode) do |size|
              @upstream.sample(size)
            end

            sample_libsamplerate(count)

          else
            raise NotImplementedError, "TODO: #{@mode.inspect}"
          end
        end

        # Zero-order hold and linear interpolator in Ruby.  See #sample.
        def sample_ruby(count, mode)
          required = required_for(count)

          # FIXME: use a circular buffer if upstreams don't like oscillating
          # between N and N+1 samples
          data = @upstream.sample(required)
          return nil if data.nil? || data.empty?

          if data.length < required
            count = count * data.length / required
            required = data.length
            return nil if count == 0
          end

          # TODO: reuse the existing buffer instead of regenerating a
          # "linspace" every time, or maybe keep a buffer for required and
          # required+1
          # XXX setup_buffer(length: count)
          case mode
          when :ruby_zoh
            Numo::SFloat.linspace(0, required - 1, count).inplace.map { |v|
              data[v.round]
            }

          when :ruby_linear
            # TODO: add a fractional lookup helper method somewhere with
            # varying interpolation modes like nearest, linear, cubic, area
            # average, etc.
            Numo::SFloat.linspace(0, required - 1, count).inplace.map { |v|
              min = v.floor
              max = v.ceil
              delta = v - min
              data[min] * (1.0 - delta) + data[max] * delta
            }

          else
            raise "BUG: unsupported mode #{mode}"
          end
        end

        # Libsamplerate resampler.  See #sample.
        def sample_libsamplerate(count)
          raise "call #sample first to initialize libsamplerate" unless @fast_resample
          @fast_resample.read(count).not_inplace! # TODO: can we return inplace?
        end

        private

        # Returns an integer number of samples to read from the upstream,
        # storing the leftover fraction in @error.
        def required_for(count)
          exact_required = @inv_ratio * count + @error
          required = exact_required.floor
          @error = exact_required - required

          # TODO: repeat the previous sample value in this case??
          raise "Ratio #{@inv_ratio} too low for count #{count} (tried to read zero samples from upstream)" if required == 0

          puts "#{self.__id__} Reading #{required} samples to return #{count}, to go from #{@upstream.sample_rate} to #{@sample_rate}; error is #{@error}" # XXX

          required
        end
      end
    end
  end
end
