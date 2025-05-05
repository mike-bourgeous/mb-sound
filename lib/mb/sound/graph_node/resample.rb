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
          @offset = 0.0
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
          exact_required = @inv_ratio * count
          endpoint = @offset + exact_required

          # FIXME: we probably need to retain prior samples for proper
          # interpolation; maybe use circular buffer class and add a seek
          # method or use direct_read or something
          #
          # I need something like a clocked circular buffer or a fractional
          # circular buffer where I can say "give me time t1 to t2 scaled to n
          # samples"
          #
          # The delay filter has some of this, as does the circular buffer.
          # The delay filter accepts an narray to control delay time but for
          # downsampling I suspect it wouldn't handle removal of old data, and
          # in either case the delay times would get unreasonable over time so
          # there'd need to be some way of resetting the delay reference.
          #
          # The circular buffer consumes samples by incrementing the read
          # pointer for the full requested amount, so it would need some
          # adaptation or wrapper to retain the extra sample(s) required and
          # indicate how many new samples are needed to fulfill a request.  And
          # again keeping a clock going without numbers growing larger and
          # larger would be a challenge.
          required = (endpoint - @offset).ceil

          # TODO: repeat the previous sample value for ZOH or interpolate through further partial fractional steps for linear
          raise "Ratio #{@inv_ratio} too low for count #{count} (tried to read zero samples from upstream)" if required == 0

          warn "#{self.__id__} Reading #{required} samples (wanted #{exact_required}) to return #{count}, to go from #{@upstream.sample_rate} to #{@sample_rate}; offset is #{@offset}...#{endpoint}" # XXX

          # FIXME: use a circular buffer or buffer adapter if upstreams don't
          # like oscillating between N and N+1 samples
          data = @upstream.sample(required)
          return nil if data.nil? || data.empty?

          if data.length < required
            # FIXME: probably missing some fractional error here
            count = count * data.length / required
            endpoint = @offset + data.length
            return nil if count == 0
          end

          # TODO: reuse the existing buffer instead of regenerating a
          # "linspace" every time, or maybe keep a buffer for each possible required size
          # XXX setup_buffer(length: count)
          case mode
          when :ruby_zoh
            ret = Numo::DFloat.linspace(@offset, endpoint - 1, count).inplace.map { |v|
              # FIXME, sometimes passes end
              data[v.round]
            }

          when :ruby_linear
            # TODO: add a fractional lookup helper method somewhere with
            # varying interpolation modes like nearest, linear, cubic, area
            # average, etc.
            ret = Numo::DFloat.linspace(@offset, endpoint - 1, count).inplace.map { |v|
              # FIXME, sometimes passes end
              min = v.floor
              max = v.ceil
              delta = v - min
              data[min] * (1.0 - delta) + data[max] * delta
            }

          else
            raise "BUG: unsupported mode #{mode}"
          end

          @offset = endpoint - endpoint.floor

          ret
        end

        # Libsamplerate resampler.  See #sample.
        def sample_libsamplerate(count)
          raise "call #sample first to initialize libsamplerate" unless @fast_resample
          @fast_resample.read(count).not_inplace! # TODO: can we return inplace?
        end
      end
    end
  end
end
