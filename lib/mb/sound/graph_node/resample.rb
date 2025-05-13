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
        # Note that some modes may add considerable latency.
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

          # TODO: identify a better fix or workaround for unfortunate integer
          # alignment than just adding a "random" starting offset.  The
          # zero-order hold interpolator could still have output glitches due
          # to a fractional sample index falling just slightly before an
          # integer.
          @zoh_offset = @inv_ratio * 0.00012345678

          @startpoint = 0.0 # Fractional sample index of start of buffer, minus discards

          @circbuf_size = 0 # Desired capacity of circular buffer

          setup_buffer(length: 1024, double: true)
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Returns +count+ samples at the new sample rate, while requesting
        # sufficient samples from the upstream node to fulfill the request.
        #
        # Note that buffers may be reused from call to call, so call #dup on
        # the returned buffer if you need to keep it outside of a normal node
        # graph or beyond one cycle of a downstream node.
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
            raise NotImplementedError, "Unsupported sample mode: #{@mode.inspect}"
          end
        end

        # Zero-order hold and linear interpolator in Ruby.  See #sample.
        def sample_ruby(count, mode)
          discard_samples(@startpoint.floor)

          exact_required = @inv_ratio * count
          endpoint = @startpoint + exact_required

          first_sample = @startpoint.floor
          last_sample = endpoint.ceil
          samples_needed = last_sample - first_sample + 1

          setup_circular_buffer(samples_needed)

          data = next_samples(samples_needed)
          return nil if data.nil?

          if data.length != samples_needed
            # FIXME: probably missing some fractional error here
            puts "Got #{data.length} instead of #{samples_needed} from upstream for count of #{count}" # XXX
            missing_ratio = data.length.to_f / samples_needed
            exact_required *= missing_ratio
            last_sample = first_sample + data.length
            endpoint = @startpoint + data.length
            count = (count * missing_ratio).floor
            return nil if count == 0
          end

          expand_buffer(data[0..0], size: count * 2)

          # TODO: reuse the existing buffer instead of regenerating a linspace
          # every time, or maybe keep a buffer for each possible required size
          case @mode
          when :ruby_zoh
            ret = (@buf[0...count].inplace.indgen * @inv_ratio + @startpoint + @zoh_offset).map_with_index { |v, idx|
              data[v.real]
            }.not_inplace!

          when :ruby_linear
            ret = (@buf[0...count].inplace.indgen * @inv_ratio + @startpoint).map_with_index { |v, idx|
              v = v.real
              idx1 = v.floor
              idx2 = v.ceil
              idx2 -= 1 if idx2 >= data.length # XXX
              delta = v - idx1
              d1 = data[idx1]
              d2 = data[idx2]
              d_out = d1 * (1.0 - delta) + d2 * delta

              d_out
            }

          else
            raise "BUG: unsupported mode #{mode}"
          end

          @startpoint = endpoint

          ret
        end

        # Libsamplerate resampler.  See #sample.
        def sample_libsamplerate(count)
          # TODO: handle complex by resampling real and imaginary separately?
          raise "call #sample first to initialize libsamplerate" unless @fast_resample
          @fast_resample.read(count)&.not_inplace! # TODO: can we return inplace?
        end

        private

        # Tells the circular buffer to advance its read pointer by +count+
        # samples, thus changing where #next_samples will read from.  This is
        # called only for samples that cannot possibly be referenced by the
        # playback range.
        def discard_samples(count)
          raise "BUG: negative discard count #{count}" if count < 0
          @circbuf.discard(count) if count > 0
          @startpoint -= count
        end

        # Retrieve the oldest +count+ samples from the circular buffer.
        # Coupled with #discard_samples, this should provide exactly the span
        # needed for interpolation above.
        #
        # Returns a short read if the upstream ends before providing +count+
        # samples.  Returns nil once the upstream has ended and the buffer is
        # empty.
        def next_samples(count)
          while @circbuf.length < count
            d = @upstream.sample(count)
            break if d.nil? || d.empty?
            @circbuf.write(d)
          end

          return nil if @circbuf.empty?

          @circbuf.peek(MB::M.min(count, @circbuf.length))
        end

        # (Re)creates the circular buffer with sufficient capacity to handle
        # two upstream reads of +count+ samples plus a little wiggle room (or
        # larger, if it was previously larger).
        def setup_circular_buffer(count)
          capacity = count * 2 + 4
          @circbuf_size = capacity if @circbuf_size < capacity
          @circbuf ||= MB::Sound::CircularBuffer.new(buffer_size: @circbuf_size)

          if @circbuf_size > @circbuf.length
            @circbuf = @circbuf.dup(@circbuf_size)
          end
        end
      end
    end
  end
end
