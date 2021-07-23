module MB
  module Sound
    class Filter
      # A simple delay line.
      class Delay
        attr_reader :delay, :delay_samples, :rate

        # Initializes a single-channel delay.  The +:buffer_size+ sets the
        # maximum possible delay (TODO: account for buffer write).
        def initialize(delay: 0, rate: 48000, buffer_size: 48000)
          @buf = Numo::SFloat.zeros(buffer_size)
          @out_buf = Numo::SFloat.zeros(1) # For wrap-around reads
          @rate = rate
          @delay = 0
          @delay_samples = 0
          @read_offset = 0
          @write_offset = 0

          self.delay = delay
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
          # TODO: add delay smoothing
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
          max_length = @buf.length - @delay_samples
          if data.length > max_length
            chunk_buf = data.inplace? ? data : data.dup.inplace

            for idx in (0...data.length).step(max_length)
              end_idx = idx + max_length
              end_idx = data.length if end_idx > data.length
              process(chunk_buf[idx...end_idx].inplace)
            end

            return chunk_buf
          end

          if @write_offset + data.length > @buf.length # TODO: just > or >=?
            before = @buf.length - @write_offset
            after = data.length - before
            @buf[@write_offset..-1] = data[0...before]
            @buf[0...after] = data[before..-1]
          else
            @buf[@write_offset...(@write_offset + data.length)] = data
          end

          # TODO: might need to be able to change/blend the delay on a per-sample basis

          if @read_offset + data.length > @buf.length # TODO: just > or >=?
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

          @read_offset = (@read_offset + data.length) % @buf.length
          @write_offset = (@write_offset + data.length) % @buf.length

          data[0..-1] = ret if data.inplace?

          ret
        end

        def response
          raise NotImplementedError, 'TODO: return a phase value based on the delay'
        end
      end
    end
  end
end
