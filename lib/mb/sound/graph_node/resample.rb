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
          @samples_consumed = 0.0

          @bufsize = 0
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
          STDERR.puts("\n\n\n-----------------------")
          warn "#{__id__} Starting resampling: count=#{count}, mode=#{mode}\n\n"

          exact_required = @inv_ratio * count
          endpoint = @offset + exact_required

          first_sample = @offset.floor
          last_sample = endpoint.ceil
          samples_needed = last_sample - first_sample + 1

          linear_start = @offset - samples_needed
          linear_end = endpoint - samples_needed

          setup_circular_buffer(samples_needed)

          data = next_samples(samples_needed)
          return nil if data.nil?

          if data.length != samples_needed
            raise 'TODO'
            # FIXME: probably missing some fractional error here
            count = count * data.length / required
            endpoint = @offset + data.length
            return nil if count == 0
          end

          STDERR.puts
          warn "#{__id__} Resampling: #{MB::U.highlight({
            :@ratio => @ratio,
            :@inv_ratio => @inv_ratio,
            :@offset => @offset,
            :@samples_consumed => @samples_consumed,
            endpoint: endpoint,
            exact_required: exact_required,
            first_sample: first_sample,
            last_sample: last_sample,
            samples_needed: samples_needed,
            linear_start: linear_start,
            linear_end: linear_end,
            linear_min: linear_start.floor,
            linear_max: linear_end.ceil,
            data_length: data.length,
            mode: mode,
          })}\n\n" # XXX

          # TODO: reuse the existing buffer instead of regenerating a linspace
          # every time, or maybe keep a buffer for each possible required size
          #
          # TODO: add a fractional lookup helper method somewhere with varying
          # interpolation modes like nearest, linear, cubic, area average, etc.
          # or find one if I already wrote it
          case mode
          when :ruby_zoh
            ret = Numo::DFloat.linspace(linear_start, linear_end, count).inplace.map { |v|
              data[v.round]
            }

          when :ruby_linear
            ret = Numo::DFloat.linspace(@offset, endpoint - 1, count).inplace.map { |v|
              min = v.floor
              max = v.ceil
              delta = v - min
              data[min] * (1.0 - delta) + data[max] * delta
            }

          else
            raise "BUG: unsupported mode #{mode}"
          end

          @samples_consumed += exact_required
          @offset = endpoint
          discard_samples(@samples_consumed.floor)

          ret
        end

        # Libsamplerate resampler.  See #sample.
        def sample_libsamplerate(count)
          raise "call #sample first to initialize libsamplerate" unless @fast_resample
          @fast_resample.read(count).not_inplace! # TODO: can we return inplace?
        end

        private

        # Tells the circular buffer to advance its read pointer by +count+
        # samples, thus changing where #next_samples will read from.  This is
        # called only for samples that cannot possibly be referenced by the
        # playback range.
        def discard_samples(count)
          warn "Request to discard #{count} samples; @offset=#{@offset}, circbuf.length=#{@circbuf.length}" # XXX

          raise "BUG: negative discard count #{count}" if count < 0
          @circbuf.discard(count) if count > 0
          @offset -= count
          @samples_consumed -= count
        end

        # Retrieve the oldest +count+ samples from the circular buffer.
        # Coupled with #discard_samples, this should provide exactly the span
        # needed for interpolation above.
        #
        # Returns a short read if the upstream ends before providing +count+
        # samples.  Returns nil once the upstream has ended and the buffer is
        # empty.
        def next_samples(count)
          warn "Requested #{count} samples"

          while @circbuf.length < count
            warn "Reading #{count} from upstream"
            d = @upstream.sample(count)
            break if d.nil? || d.empty?
            @circbuf.write(d)
          end

          return nil if @circbuf.empty?

          @circbuf.peek(MB::M.min(count, @circbuf.length)).tap { |v|
            warn "Returning #{v.length} samples"
          }
        end

        # (Re)creates the circular buffer with sufficient capacity to handle
        # two upstream reads of +count+ samples plus a little wiggle room (or
        # larger, if it was previously larger).
        def setup_circular_buffer(count)
          capacity = count * 2 + 4
          @bufsize = capacity if @bufsize < capacity
          @circbuf ||= MB::Sound::CircularBuffer.new(buffer_size: @bufsize)

          if @bufsize > @circbuf.length
            @circbuf = @circbuf.dup(@bufsize)
          end
        end
      end
    end
  end
end
