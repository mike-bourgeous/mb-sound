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

        # Sets the delay time in +samples+, regardless of sample rate.  The
        # number of +samples+ will be rounded to the closest Integer.
        def delay_samples=(samples)
          samples = samples.round
          raise 'Delay must be less than buffer size' if samples >= @buf.length

          delta = samples - @delay_samples
          @delay_samples = samples
          @read_offset = (@read_offset - delta) % @buf.length
        end

        # Sets the delay time in +seconds+, which is converted to a number of
        # samples using the sample rate.
        def delay=(seconds)
          self.delay_samples = seconds * @rate
          @delay = seconds.to_f
        end

        def process(data)
          # TODO is this true? or what is true?
          raise 'Cannot write more than the buffer size minus the delay in samples' if data.length > @buf.length - @delay_samples

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

          ret
        end

        def response
          raise NotImplementedError, 'TODO: return a phase value based on the delay'
        end
      end
    end
  end
end
