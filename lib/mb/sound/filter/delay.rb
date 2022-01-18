module MB
  module Sound
    class Filter
      # A simple delay line.
      class Delay < Filter
        attr_reader :delay, :delay_samples, :rate, :smoothing

        # Initializes a single-channel delay with a given +:delay+ in seconds,
        # based on the sample +:rate+..  The +:buffer_size+ sets the maximum
        # possible delay.  If +:smoothing+ is true, then the delay time will be
        # adjusted slowly to prevent sudden jumps or clicks in the output.  If
        # +:smoothing+ is a numeric value, then that is the maximum delay
        # change in seconds allowed per second.
        def initialize(delay: 0, rate: 48000, buffer_size: 48000, smoothing: true)
          buffer_size = 1.1 * delay * rate if buffer_size < 1.1 * delay * rate
          @buf = Numo::SFloat.zeros(buffer_size)
          @out_buf = Numo::SFloat.zeros(1) # For wrap-around reads
          @rate = rate.to_f
          @delay = 0
          @delay_samples = 0
          @read_offset = 0
          @write_offset = 0

          self.delay = delay

          @smoothing = !!smoothing
          @smooth_limit = @rate * (smoothing.is_a?(Numeric) ? smoothing : 0.5)
          @filter = MB::Sound::Filter::LinearFollower.new(
            rate: @rate,
            max_rise: @smooth_limit,
            max_fall: @smooth_limit
          )
          @filter.reset(@delay_samples)
          @filter_buf = Numo::Int32.zeros(buffer_size).fill(@delay_samples)
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
        # #delay= or #delay_samples=.
        def reset_delay
          @filter.reset(@delay_samples)
        end

        # Enables or disables delay smoothing, and resets the smoothed delay to
        # the current target delay value set by #delay= or #delay_samples=.
        # See #reset_delay.
        def smoothing=(enabled)
          reset_delay
          @smoothing = !!enabled
        end

        # Sets the delay time in +samples+, regardless of sample rate.  The
        # number of +samples+ will be rounded to the closest Integer.
        def delay_samples=(samples)
          samples = samples.round
          raise 'Delay must be less than buffer size' if samples >= @buf.length

          delta = samples - @delay_samples
          @delay_samples = samples
          @delay = samples.to_f / @rate
          @read_offset = (@read_offset - delta) % @buf.length
        end

        # Sets the delay time in +seconds+, which is converted to a number of
        # samples using the sample rate.
        def delay=(seconds)
          self.delay_samples = seconds * @rate
        end

        # Delays the given +data+ by #delay_samples samples.
        def process(data)
          raise 'Cannot process a zero-length array' if data.length == 0

          if @buf.is_a?(Numo::SFloat) && (data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex))
            @buf = Numo::SComplex.cast(@buf)
          end

          if @smoothing
            max_length = @buf.length - MB::M.max(@delay_samples, @filter.peek)
          else
            max_length = @buf.length - @delay_samples
          end

          if data.length > max_length
            chunk_buf = data.inplace? ? data : data.dup.inplace

            for idx in (0...data.length).step(max_length)
              end_idx = idx + max_length
              end_idx = data.length if end_idx > data.length
              process(chunk_buf[idx...end_idx].inplace)
            end

            return chunk_buf
          end

          if @write_offset + data.length > @buf.length
            before = @buf.length - @write_offset
            after = data.length - before
            @buf[@write_offset..-1] = data[0...before]
            @buf[0...after] = data[before..-1]
          else
            @buf[@write_offset...(@write_offset + data.length)] = data
          end

          if @smoothing
            # TODO: Fractional addressing / interpolation / resampling might sound better
            # TODO: Support using an NArray as the delay value
            delay = @filter.process(@filter_buf[0...data.length].fill(@delay_samples).inplace).not_inplace!
            ret = data.map_with_index { |_, idx|
              read_offset = (@write_offset - delay[idx] + idx) % @buf.length
              @buf[read_offset]
            }
          else
            if @read_offset + data.length > @buf.length
              # Wrap-around read
              before = @buf.length - @read_offset
              after = data.length - before
              @out_buf = Numo::SFloat.zeros(data.length) if @out_buf.length != data.length
              @out_buf[0...before] = @buf[@read_offset..-1]
              @out_buf[before..-1] = @buf[0...after]
              ret = @out_buf
            else
              ret = @buf[@read_offset...(@read_offset + data.length)]
            end
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
