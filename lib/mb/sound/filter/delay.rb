module MB
  module Sound
    class Filter
      # A fractionally addressed delay line, allowing dynamic changes of the
      # delay time and odd pitch shift effects.
      #
      # See bin/flanger.rb and bin/tape_delay.rb for examples.
      class Delay < Filter
        include GraphNode::SampleRateHelper

        # The default delay-time smoothing rate in seconds per second.
        DEFAULT_SMOOTHING_RATE = 0.5

        attr_reader :delay, :delay_samples, :smoothing, :smooth_limit

        attr_reader :write_offset, :read_offset

        # Minimum, maximum, and final delay in samples from the previous call
        # to #process.  May not be an integer.
        attr_reader :min_delay_samples, :max_delay_samples, :last_delay_samples

        # The feedback gain, wet level, and dry level: numbers or graph nodes
        # (see #feedback=, #wet=, #dry=).
        attr_reader :feedback, :wet, :dry

        # How fractional delays are interpolated (see
        # MB::Sound::DelayLine::INTERPOLATION).
        attr_reader :interpolation

        # Initializes a single-channel delay with a given +:delay+ in seconds,
        # based on the +:sample_rate+..  The +:delay_buffer_size+ sets the
        # initial buffer size in samples; the buffer grows (keeping its
        # audio) if a longer delay is needed, but growing allocates memory.
        #
        # If +:smoothing+ is true (the default), then the delay time will be
        # adjusted slowly to prevent sudden jumps or clicks in the output.  If
        # +:smoothing+ is a numeric value, then that is the maximum delay
        # change in seconds allowed per second.  The default smoothing rate is
        # MB::Sound::Filter::Delay::DEFAULT_SMOOTHING_RATE.
        #
        # The output is +:wet+ times the delayed signal plus +:dry+ times the
        # input.  A +:feedback+ gain feeds the delayed signal back into the
        # delay.  Each may be a number or a graph node (e.g. an LFO or a MIDI
        # CC) giving a value per sample.
        #
        # +:interpolation+ chooses how fractional delays are read: :linear,
        # :cubic, or :sinc (see MB::Sound::DelayLine).
        def initialize(delay: 0, sample_rate: 48000, delay_buffer_size: 48000, smoothing: true, feedback: false, wet: 1, dry: 0, interpolation: :linear)
          @sample_rate = sample_rate.to_f

          if delay.is_a?(Numeric)
            delay_buffer_size = 1.1 * delay * @sample_rate if delay_buffer_size < 1.1 * delay * @sample_rate
          end

          @line = MB::Sound::DelayLine.new(delay_buffer_size)
          self.interpolation = interpolation
          @read_state = []
          @delay = 0
          @delay_samples = 0
          @smooth_limit = nil

          @filter_buf = Numo::SFloat.zeros(1)

          self.feedback = feedback
          self.dry = dry
          self.wet = wet

          self.delay = delay
          self.smoothing = smoothing
        end

        # The size of the delay buffer in samples.
        def delay_buffer_size
          @line.capacity
        end

        # Where the next input sample will be written in the delay buffer.
        def write_offset
          @line.write_offset
        end

        # Where a constant delay reads its next output sample in the delay
        # buffer.
        def read_offset
          delay = @delay_samples.is_a?(Numeric) ? @delay_samples : @last_delay_samples.to_f.round
          (@line.write_offset - delay) % @line.capacity
        end

        # Fills the entire delay line with the given value.  Future calls to
        # #process will return this value for #delay_samples samples, before
        # returning the newly written data.
        def reset(value = 0)
          @line.fill(value)
          reset_delay
        end

        # Immediately sets the smoothed internal delay to +samples+, or to the
        # last value set by #delay= or #delay_samples=.  Without +samples+,
        # this has no effect if the delay was set to a signal node with a
        # :sample method (see GraphNode and #delay=).
        def reset_delay(samples = nil)
          # TODO: Support resetting with a signal node without consuming a
          # sample from the signal node?  Maybe set a flag that triggers a
          # reset in #sample?
          samples ||= @delay_samples if @delay_samples.is_a?(Numeric)
          @filter.reset(samples) if samples
        end

        # Changes the sample rate of the delay, cascading the rate change to
        # any upstream sources and recomputing delay values in samples.
        def sample_rate=(new_rate)
          raise "Filter #{@filter} does not support changing sample rate" if @filter && !@filter.respond_to?(:at_rate)

          super

          @filter = @filter&.at_rate(new_rate)

          if @delay_seconds_orig
            self.delay = @delay_seconds_orig
          elsif @delay_samples
            self.delay_samples = @delay_samples
          end

          self
        end
        alias at_rate sample_rate=

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
            check_rate(smoothing, 'smoothing')
            @filter = smoothing
            @smooth_limit = nil
          else
            new_limit = @sample_rate * (smoothing.is_a?(Numeric) ? smoothing : DEFAULT_SMOOTHING_RATE)
            if new_limit != @smooth_limit
              @smooth_limit = new_limit
              @filter = MB::Sound::Filter::LinearFollower.new(
                sample_rate: @sample_rate,
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
          @delay_seconds_orig = nil
          if samples.respond_to?(:sample)
            # TODO: use dynamic_process instead of managing the upstream source here
            samples = samples.get_sampler
            check_rate(samples, 'delay_samples')
            @delay_samples = samples
            @delay = samples / @sample_rate
            @min_delay_samples = 0
            @max_delay_samples = 0
            @last_delay_samples = 0
          else
            samples = samples.round
            @delay_samples = samples
            @min_delay_samples = @delay_samples
            @max_delay_samples = @delay_samples
            @last_delay_samples = @delay_samples
            @delay = samples.to_f / @sample_rate
          end
        end

        # Sets the delay time in +seconds+, which is converted to a number of
        # samples using the sample rate.
        def delay=(seconds)
          check_rate(seconds, 'delay_seconds')
          self.delay_samples = seconds * @sample_rate
          @delay_seconds_orig = seconds
        end

        # Sets the interpolation mode for fractional delays (:linear, :cubic,
        # or :sinc; see MB::Sound::DelayLine).
        def interpolation=(mode)
          unless MB::Sound::DelayLine::INTERPOLATION.include?(mode)
            raise ArgumentError, "Unknown interpolation #{mode.inspect} (use one of #{MB::Sound::DelayLine::INTERPOLATION.keys.join(', ')})"
          end
          @interpolation = mode
        end

        # Sets the feedback gain: a number (false or nil for none) or a graph
        # node giving a gain per sample.
        def feedback=(gain)
          @feedback = control(gain, 'feedback') || false
        end

        # Sets the wet (delayed signal) level: a number or a graph node.
        def wet=(level)
          @wet = control(level, 'wet')
        end

        # Sets the dry (input) level: a number or a graph node.
        def dry=(level)
          @dry = control(level, 'dry')
        end

        # Returns a copy of the current delay buffer, rotated so that the write
        # pointer is always at the start of the returned buffer copy, for
        # visualization use.
        def buffer
          @line.unwrapped
        end

        # Returns an Array of signal nodes and/or numeric values that feed this
        # delay (specifically for a delay this is the value given to
        # #delay_samples=).  See GraphNode#sources.
        def sources
          { delay_samples: @delay_samples }.merge(
            { feedback: @feedback, wet: @wet, dry: @dry }.select { |_, v| v.respond_to?(:sample) }
          )
        end

        # Delays the given +data+ by #delay_samples samples, returning +wet+
        # times the delayed signal plus +dry+ times the input (in +data+
        # itself if it is in-place).  Returns nil if a delay time node ends.
        def process(data)
          raise 'Cannot process a zero-length array' if data.length == 0

          delays = delay_buffer(data.length)
          return nil if delays.equal?(:end)

          if delays.is_a?(Numeric)
            @min_delay_samples = @max_delay_samples = @last_delay_samples = delays
            max_delay = delays
          elsif delays
            data = data[0...delays.length] if data.length > delays.length
            delays = delays[0...data.length] if delays.length > data.length
            @min_delay_samples, @max_delay_samples = delays.minmax
            @last_delay_samples = delays[-1]
            max_delay = @max_delay_samples
          else
            max_delay = @delay_samples
          end

          feedback = control_values(@feedback, data.length)
          wet = control_values(@wet, data.length)
          dry = control_values(@dry, data.length)
          return nil if feedback.nil? || wet.nil? || dry.nil?

          length = [data, feedback, wet, dry].map { |v| v.respond_to?(:length) ? v.length : data.length }.min
          if length < data.length
            data = data[0...length]
            delays = delays[0...length] if delays.respond_to?(:length)
          end

          complex = [data, feedback].any? { |v| v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex) || v.is_a?(Complex) }
          @line.prepare(data.length, max_delay, complex ? Numo::SComplex : data.class)

          if feedback && feedback != 0
            delayed = @line.feedback(data, delays || @delay_samples, feedback.is_a?(Numo::NArray) ? feedback[0...length] : feedback, interpolation: @interpolation, state: @read_state)
          else
            @line.write(data)
            delayed = @line.read(data.length, delays || @delay_samples, interpolation: @interpolation, state: @read_state)
          end

          result = wet.is_a?(Numo::NArray) ? delayed * wet[0...length] : wet * delayed
          if dry.is_a?(Numo::NArray)
            result = result + data * dry[0...length]
          elsif dry != 0
            result = result + dry * data
          end

          if data.inplace?
            data[true] = result
            data
          else
            result
          end
        end

        def response
          raise NotImplementedError, 'TODO: return a phase value based on the delay'
        end

        def to_s
          "Delay -- interpolation=#{@interpolation} smoothing=#{@smoothing} smooth_limit=#{@smooth_limit} feedback=#{level(@feedback, false)} dry=#{level(@dry)} wet=#{level(@wet)}"
        end

        def to_s_graphviz
          "Delay\ninterpolation: #{@interpolation}\nsmoothing: #{@smoothing}\nsmooth_limit: #{@smooth_limit}\nfeedback: #{level(@feedback, false)}\ndry: #{level(@dry)}\nwet: #{level(@wet)}"
        end

        private

        # Checks a feedback/wet/dry value: a graph node (sampled per buffer,
        # through get_sampler) or a number (false/nil allowed for feedback).
        def control(value, name)
          if value.respond_to?(:sample)
            value = value.get_sampler
            check_rate(value, name)
            value
          elsif value.nil? || value == false
            name == 'feedback' ? false : raise(ArgumentError, "#{name} must be a number or a graph node")
          elsif value.is_a?(Numeric)
            value.is_a?(Complex) ? value : value.to_f
          else
            raise ArgumentError, "#{name} must be a number or a graph node (got #{value.inspect})"
          end
        end

        # Returns +count+ values of a control (one per sample) for a node,
        # nil if the node ended, or the number itself.
        def control_values(value, count)
          value.respond_to?(:sample) ? value.sample(count) : value
        end

        # Describes a level for #to_s (dB for numbers).
        def level(value, db = true)
          return value.to_s if value.respond_to?(:sample) || !value.is_a?(Numeric) || !db
          value.to_db
        end

        # Returns the delay in samples for each of +count+ samples (smoothed
        # if smoothing is on), a Numeric delay for every sample (nil for the
        # constant #delay_samples), or :end if the delay time node ended.
        #
        # Once the default smoothing (a LinearFollower) has reached a
        # constant target, the filter is skipped (it would output the
        # target unchanged), so settled delays read as constant delays.
        def delay_buffer(count)
          settled = @smoothing && @filter.is_a?(MB::Sound::Filter::LinearFollower)

          if @delay_samples.respond_to?(:sample)
            # TODO: maybe upstream sampling should be moved to SampleWrapper
            # and we should use a dynamic_process method for processing with
            # multiple inputs
            delays = @delay_samples.sample(count)
            return :end if delays.nil?

            if settled
              min, max = delays.minmax
              return min.to_f if min == max && min == @filter.peek
            end
          elsif settled && @filter.peek == @delay_samples
            return nil
          elsif @smoothing
            @filter_buf = Numo::SFloat.zeros(count) if @filter_buf.length < count
            delays = @filter_buf[0...count].fill(@delay_samples)
          else
            return nil
          end

          delays = @filter.process(delays.inplace).not_inplace! if @smoothing
          delays
        end
      end
    end
  end
end
