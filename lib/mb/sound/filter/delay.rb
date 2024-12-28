module MB
  module Sound
    class Filter
      # A fractionally addressed delay line, allowing dynamic changes of the
      # delay time and odd pitch shift effects.
      #
      # See bin/flanger.rb and bin/tape_delay.rb for examples.
      class Delay < Filter
        # The default delay-time smoothing rate in seconds per second.
        DEFAULT_SMOOTHING_RATE = 0.5

        attr_reader :delay, :delay_samples, :rate, :smoothing, :smooth_limit
        attr_reader :write_offset, :read_offset

        # Minimum, maximum, and final delay in samples from the previous call
        # to #process.  May not be an integer.
        attr_reader :min_delay_samples, :max_delay_samples, :last_delay_samples

        # Initializes a single-channel delay with a given +:delay+ in seconds,
        # based on the sample +:rate+..  The +:buffer_size+ sets the maximum
        # possible delay.
        #
        # If +:smoothing+ is true (the default), then the delay time will be
        # adjusted slowly to prevent sudden jumps or clicks in the output.  If
        # +:smoothing+ is a numeric value, then that is the maximum delay
        # change in seconds allowed per second.  The default smoothing rate is
        # MB::Sound::Filter::Delay::DEFAULT_SMOOTHING_RATE.
        def initialize(delay: 0, rate: 48000, buffer_size: 48000, smoothing: true)
          if delay.is_a?(Numeric)
            buffer_size = 1.1 * delay * rate if buffer_size < 1.1 * delay * rate
          end

          @buf = Numo::SFloat.zeros(buffer_size)
          @out_buf = Numo::SFloat.zeros(1) # For wrap-around reads
          @rate = rate.to_f
          @delay = 0
          @delay_samples = 0
          @read_offset = 0
          @write_offset = 0
          @smooth_limit = nil

          @filter_buf = Numo::SFloat.zeros(buffer_size)

          self.delay = delay
          self.smoothing = smoothing
        end

        def buffer_size
          @buf.length
        end

        # Fills the entire delay line with the given value.  Future calls to
        # #process will return this value for #delay_samples samples, before
        # returning the newly written data.
        def reset(value = 0)
          @buf.fill(value)
          @out_buf.fill(value)
          reset_delay
        end

        # Immediately sets the smoothed internal delay to the last value set by
        # #delay= or #delay_samples=.  Has no effect if the delay was set to a
        # signal node with a :sample method (see GraphNode and #delay=).
        def reset_delay
          # TODO: Support resetting with a signal node without consuming a
          # sample from the signal node?  Maybe set a flag that triggers a
          # reset in #sample?
          if @delay_samples.is_a?(Numeric)
            @filter.reset(@delay_samples)
          end
        end

        # Enables or disables delay smoothing, and resets the smoothed delay to
        # the current target delay value set by #delay= or #delay_samples=.
        #
        # Pass a numeric value for +smoothing+ to control how many seconds the
        # delay time can change per second of output time (the default is 0.5).
        # This is basically the same thing as controlling how slow the playback
        # of the delay buffer can get.
        #
        # Pass a Filter for +smoothing+ to directly set a smoothing filter or
        # filter chain.
        #
        # See #reset_delay.
        def smoothing=(smoothing)
          @smoothing = !!smoothing

          if smoothing.respond_to?(:process) && smoothing.respond_to?(:reset)
            @filter = smoothing
            @smooth_limit = nil
          else
            new_limit = @rate * (smoothing.is_a?(Numeric) ? smoothing : DEFAULT_SMOOTHING_RATE)
            if new_limit != @smooth_limit
              @smooth_limit = new_limit
              @filter = MB::Sound::Filter::LinearFollower.new(
                rate: @rate,
                max_rise: @smooth_limit,
                max_fall: @smooth_limit
              )
            end
          end

          reset_delay
        end

        # Sets the delay time in +samples+, regardless of sample rate.  The
        # number of +samples+ will be rounded to the closest Integer.
        def delay_samples=(samples)
          if samples.respond_to?(:sample)
            @delay_samples = samples
            @delay = samples / @rate
            @min_delay_samples = 0
            @max_delay_samples = 0
            @last_delay_samples = 0
          else
            samples = samples.round
            # If samples exceeds buffer size, the buffer will grow in #sample
            # (not ideal for realtime use due to allocation, but it works)

            delta = samples - @delay_samples
            @delay_samples = samples
            @min_delay_samples = @delay_samples
            @max_delay_samples = @delay_samples
            @last_delay_samples = @delay_samples
            @delay = samples.to_f / @rate
            @read_offset = (@write_offset - @delay_samples) % @buf.length
          end
        end

        # Sets the delay time in +seconds+, which is converted to a number of
        # samples using the sample rate.
        def delay=(seconds)
          self.delay_samples = seconds * @rate
        end

        # Returns a copy of the current delay buffer, rotated so that the write
        # pointer is always at the start of the returned buffer copy.
        def buffer
          MB::M.rol(@buf, @write_offset) # TODO: create and reuse a single buffer
        end

        # Returns an Array of signal nodes and/or numeric values that feed this
        # delay (specifically for a delay this is the value given to
        # #delay_samples=).  See GraphNode#sources.
        def sources
          [@delay_samples]
        end

        # Delays the given +data+ by #delay_samples samples.
        #
        # The +:chunk_delay_buf+ parameter is used internally for recursive
        # calls to process chunks of data longer than the delay buffer.
        def process(data, chunk_delay_buf: nil)
          raise 'Cannot process a zero-length array' if data.length == 0

          if @buf.is_a?(Numo::SFloat) && (data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex))
            @buf = Numo::SComplex.cast(@buf)
          end

          # Fill a buffer with the intended delay at each sample (if
          # chunk_delay_buf is set, then this buffer was already generated and
          # this is a recursive call for a subset of the incoming data).
          if chunk_delay_buf
            delay_buf = chunk_delay_buf
          else
            if @delay_samples.respond_to?(:sample)
              delay_buf = @delay_samples.sample(data.length)
              return nil if delay_buf.nil? # end of input
            elsif @smoothing
              if @filter_buf.length < data.length
                @filter_buf = Numo::SFloat.zeros(data.length)
              end

              delay_buf = @filter_buf[0...data.length].fill(@delay_samples)
            end

            if @smoothing
              delay_buf = @filter.process(delay_buf.inplace).not_inplace!
            end
          end

          if delay_buf
            max_delay = delay_buf.max.ceil
          else
            max_delay = @delay_samples.ceil
          end

          # If there's zero room in the delay buffer given the maximum delay,
          # grow the delay buffer (this should only happen if we have a dynamic
          # delay source with long delays).
          max_length = @buf.length - max_delay
          if max_length <= 0
            max_length += 2 * max_delay
            old_buf = @buf
            @buf = old_buf.class.zeros(old_buf.length + 2 * max_delay)
            @buf[0...old_buf.length] = old_buf

            @read_offset = (@write_offset - max_delay) % @buf.length
          end

          # Switch to chunked processing if there's not enough room in the
          # delay buffer for the entire incoming data, given the maximum delay.
          if data.length > max_length
            chunk_buf = data.inplace? ? data : data.dup.inplace

            for idx in (0...data.length).step(max_length)
              end_idx = idx + max_length
              end_idx = data.length if end_idx > data.length
              process(chunk_buf[idx...end_idx].inplace, chunk_delay_buf: delay_buf&.[](idx...end_idx))
            end

            return chunk_buf
          end

          # Copy the new data into the delay buffer
          MB::M.circular_write(@buf, data, @write_offset)

          if delay_buf
            # Time-varying delay
            @min_delay_samples, @max_delay_samples = delay_buf.minmax
            @last_delay_samples = delay_buf[-1]

            # TODO: Something better than linear interpolation?
            # TODO: Allow switching off interpolation?
            ret = data.map_with_index { |_, idx|
              delay = delay_buf[idx] # TODO: does this need to clamp to >= 0 ???
              min = delay.floor
              max = delay.ceil
              delta = delay - min
              @read_offset = (@write_offset - min + idx) % @buf.length
              off2 = (@write_offset - max + idx) % @buf.length
              @buf[@read_offset] * (1.0 - delta) + @buf[off2] * delta
            }
          else
            # Constant delay
            @out_buf = Numo::SFloat.zeros(data.length) if @out_buf.length < data.length
            ret = MB::M.circular_read(@buf, @read_offset, data.length, target: @out_buf[0...data.length])
          end

          @read_offset = (@read_offset + data.length) % @buf.length
          @write_offset = (@write_offset + data.length) % @buf.length

          data[0..-1] = ret if data.inplace? && data.object_id != ret.object_id

          ret
        end

        def response
          raise NotImplementedError, 'TODO: return a phase value based on the delay'
        end
      end
    end
  end
end
