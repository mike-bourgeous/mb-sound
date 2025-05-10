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

          @upstream_sample_index = 0.0 # Upstream fractional sample index of first sample in output buffer
          @downstream_sample_index = 0 # Downstream integer sample index of first sample in output buffer
          @startpoint = 0.0 # Fractional sample index of start of buffer, minus discards
          @samples_consumed = 0.0 # Cumulative fractional samples retrieved, minus discards
          @buffer_start = 0 # Upstream integer sample index of first sample in circular buffer

          @bufsize = 0 # Desired capacity of circular buffer
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
          STDERR.puts("\n\n\n-----------------------") if $DEBUG # XXX
          warn "#{__id__} Starting resampling: count=#{count}, mode=#{mode}\n\n" if $DEBUG

          exact_required = @inv_ratio * count
          endpoint = @startpoint + exact_required

          first_sample = @startpoint.floor
          last_sample = endpoint.ceil
          samples_needed = last_sample - first_sample + 1

          negative_fractional_start = @startpoint - samples_needed
          negative_fractional_end = endpoint - samples_needed
          while negative_fractional_start >= exact_required
            puts "Subtracting" # XXX
            negative_fractional_start -= exact_required
            negative_fractional_end -= exact_required
          end

          setup_circular_buffer(samples_needed)

          data = next_samples(samples_needed)
          return nil if data.nil?

          if data.length != samples_needed
            raise "TODO: asked for #{samples_needed} got #{data.length}"
            # FIXME: probably missing some fractional error here
            count = count * data.length / required
            endpoint = @startpoint + data.length
            return nil if count == 0
          end

          effective_negative_start = negative_fractional_start + data.length + @buffer_start
          effective_negative_end = negative_fractional_end + data.length + @buffer_start

          if $DEBUG # XXX
            STDERR.puts
            warn "#{__id__} Resampling: #{MB::U.highlight({
              :@ratio => @ratio,
              :@inv_ratio => @inv_ratio,
              :@samples_consumed => @samples_consumed,
              :@buffer_start => @buffer_start,
              :@upstream_sample_index => @upstream_sample_index,
              :@downstream_sample_index => @downstream_sample_index,
              :@startpoint => @startpoint,
              endpoint: endpoint,
              exact_required: exact_required,
              global_first: @upstream_sample_index.floor,
              global_last: (@upstream_sample_index + exact_required).ceil,
              first_sample: first_sample,
              last_sample: last_sample,
              samples_needed: samples_needed,
              negative_fractional_start: negative_fractional_start,
              negative_fractional_end: negative_fractional_end,
              negative_fractional_min: negative_fractional_start.floor,
              negative_fractional_max: negative_fractional_end.ceil,
              data_length: data.length,
              mode: mode,
              effective_negative_start: effective_negative_start,
              effective_negative_end: effective_negative_end,
              effective_start_delta: effective_negative_start - @upstream_sample_index,
              effective_end_delta: effective_negative_end - @upstream_sample_index - exact_required,
            })}\n\n" # XXX
          end

          # TODO: reuse the existing buffer instead of regenerating a linspace
          # every time, or maybe keep a buffer for each possible required size
          case mode
          when :ruby_zoh
            # XXX require 'pry-byebug'; binding.pry if @downstream_sample_index >= 9999
            ret = Numo::DFloat.linspace(negative_fractional_start, negative_fractional_end, count + 1)[0...-1].inplace.map_with_index { |v, idx|
              data[v.floor]
            }

          when :ruby_linear
            # TODO: Use MB::M.fractional_index()?
            ret = Numo::DFloat.linspace(negative_fractional_start, negative_fractional_end, count + 1)[0...-1].inplace.map_with_index { |v, idx|
              idx1 = v.floor
              idx2 = v.ceil
              delta = v - idx1
              d1 = data[idx1]
              d2 = data[idx2]
              d_out = d1 * (1.0 - delta) + d2 * delta

              d_out
            }

          else
            raise "BUG: unsupported mode #{mode}"
          end

          @samples_consumed += exact_required
          @upstream_sample_index += exact_required
          @downstream_sample_index += ret.length
          @startpoint = endpoint
          discard_samples(@samples_consumed.floor)

          ret
        end

        # Libsamplerate resampler.  See #sample.
        def sample_libsamplerate(count)
          # TODO: handle complex by resampling real and imaginary separately?
          raise "call #sample first to initialize libsamplerate" unless @fast_resample
          @fast_resample.read(count).not_inplace! # TODO: can we return inplace?
        end

        private

        # Tells the circular buffer to advance its read pointer by +count+
        # samples, thus changing where #next_samples will read from.  This is
        # called only for samples that cannot possibly be referenced by the
        # playback range.
        def discard_samples(count)
          warn "Request to discard #{count} samples; @startpoint=#{@startpoint}, circbuf.length=#{@circbuf.length}" if $DEBUG # XXX

          raise "BUG: negative discard count #{count}" if count < 0
          # FIXME: discarding an integer number of samples isn't exactly right.
          # I need a way to refer to samples by index.
          @circbuf.discard(count) if count > 0
          @startpoint -= count
          @samples_consumed -= count
          @buffer_start += count
        end

        # Retrieve the oldest +count+ samples from the circular buffer.
        # Coupled with #discard_samples, this should provide exactly the span
        # needed for interpolation above.
        #
        # Returns a short read if the upstream ends before providing +count+
        # samples.  Returns nil once the upstream has ended and the buffer is
        # empty.
        def next_samples(count)
          warn "Requested #{count} samples" if $DEBUG

          while @circbuf.length < count
            warn "Reading #{count} from upstream" if $DEBUG
            d = @upstream.sample(count)
            break if d.nil? || d.empty?
            @circbuf.write(d)
          end

          return nil if @circbuf.empty?

          @circbuf.peek(MB::M.min(count, @circbuf.length)).tap { |v|
            warn "Returning #{v.length} samples" if $DEBUG
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
