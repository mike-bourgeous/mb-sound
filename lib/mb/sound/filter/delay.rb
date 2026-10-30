module MB
  module Sound
    class Filter
      # A fractionally addressed delay line, allowing dynamic changes of the
      # delay time and odd pitch shift effects.
      #
      # See bin/flanger.rb and bin/tape_delay.rb for examples.
      class Delay < Filter
        include GraphNode::SampleRateHelper
        node_traits memory: :long

        # The default delay-time smoothing rate in seconds per second.
        DEFAULT_SMOOTHING_RATE = 0.5

        # The delay time as given (seconds, a Length such as 5.samples, a
        # Duration, or a graph node; see #delay=).
        attr_reader :delay

        attr_reader :smoothing, :smooth_limit

        # Minimum, maximum, and final delay in samples from the previous call
        # to #process.  May not be an integer.
        attr_reader :min_delay_samples, :max_delay_samples, :last_delay_samples

        # The wet level and dry level: numbers or graph nodes (see #wet=,
        # #dry=).  (Feedback is GraphNode#delay's: a FeedbackLoop around a
        # Delay since smoothing-1.)
        attr_reader :wet, :dry

        # How fractional delays are interpolated (see
        # MB::Sound::DelayLine::INTERPOLATION).
        attr_reader :interpolation

        # Samples subtracted from the delay after smoothing (nil or 0 for
        # none): set by a GraphNode::FeedbackLoop running its body as a block
        # graph, to make up for the loop's block latency.
        attr_accessor :loop_offset

        # Initializes a single-channel delay with a +:delay+ time: a number of
        # seconds, a length (`5.samples`, `250.ms`, `3.n16`), or a graph node
        # (see #delay=).  The time keeps its unit when the sample rate
        # changes (e.g. inside GraphNode#oversample, 5.samples stays 5
        # samples at the new rate and 0.01 seconds stays 0.01 seconds).  The
        # +:delay_buffer_size+ sets the initial buffer size in samples; the
        # buffer grows (keeping its audio) if a longer delay is needed, but
        # growing allocates memory.
        #
        # If +:smoothing+ is true (the default), then the delay time will be
        # adjusted slowly to prevent sudden jumps or clicks in the output.  If
        # +:smoothing+ is a numeric value, then that is the maximum delay
        # change in seconds allowed per second.  The default smoothing rate is
        # MB::Sound::Filter::Delay::DEFAULT_SMOOTHING_RATE.
        #
        # The output is +:wet+ times the delayed signal plus +:dry+ times the
        # input.  Each may be a number or a graph node (e.g. an LFO or a MIDI
        # CC) giving a value per sample.  (Feedback: GraphNode#delay's
        # feedback:, a FeedbackLoop.)
        #
        # +:interpolation+ chooses how fractional delays are read: :linear,
        # :cubic, or :sinc (see MB::Sound::DelayLine).
        #
        # With +:ring_out+ (the default), a SampleWrapper keeps playing the
        # delay's tail after its input ends (see #ring_out).
        def initialize(delay: 0, sample_rate: 48000, delay_buffer_size: 48000, smoothing: true, wet: 1, dry: 0, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, ring_out: true)
          @sample_rate = sample_rate.to_f
          @ring_out = ring_out
          @smooth_limit = nil
          @filter = nil
          @seed_node = false # (see #reset_delay)

          self.delay = delay

          longest = @time.max_samples(@sample_rate)
          delay_buffer_size = 1.1 * longest if longest && delay_buffer_size < 1.1 * longest

          @line = MB::Sound::DelayLine.new(delay_buffer_size)
          self.interpolation = interpolation
          @read_state = []

          @filter_buf = Numo::SFloat.zeros(1)

          self.dry = dry
          self.wet = wet

          self.smoothing = smoothing

          # Set while processing (here so every Delay has one instance
          # variable layout; see GraphNode::IvarPreset)
          @delay_range = nil
          @read_buf = nil
          @result_buf = nil
          @dry_buf = nil # (see #gains_reused)
          @minmax = [0.0, 0.0] # (reused by #delay_buffer)
          @ring = nil
          @ring_zeros = nil
          @frozen_copy = nil
          @loop_offset = nil
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
          (@line.write_offset - @last_delay_samples.to_f.round) % @line.capacity
        end

        # The delay in samples at the current sample rate: a number, or the
        # graph node for a delay that changes every sample.
        def delay_samples
          @time.node? ? @time.node : @time.constant_samples(@sample_rate)
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
        # for a delay set to a signal node, the smoothed delay starts at the
        # node's next value (the first sample of the next buffer; since
        # omnibus16: a node time used to glide up from 0 at the smoothing
        # rate, 0.5 samples per sample, so a 0.3 s delay took 0.6 s to
        # arrive).
        def reset_delay(samples = nil)
          samples ||= @time.constant_samples(@sample_rate) unless @time.node?
          # A tempo-synced delay starts at its time at the current tempo
          samples ||= (tempo = @time.tempo_node) && tempo.value * @sample_rate
          @seed_node = samples.nil? && @time.node?
          @filter.reset(samples) if samples && @filter
        end

        # Changes the sample rate of the delay, cascading the rate change to
        # any upstream sources.  The delay time keeps its unit (see #delay=),
        # so nothing needs rebuilding.
        def sample_rate=(new_rate)
          raise "Filter #{@filter} does not support changing sample rate" if @filter && @smoothing_setting.respond_to?(:process) && !@filter.respond_to?(:at_rate)

          old_rate = @sample_rate

          super

          @filter = MB::Sound::DelayLine.rescale_smoother(@filter, @smoothing_setting, old_rate, @sample_rate)
          @smooth_limit = @sample_rate * (@smoothing_setting.is_a?(Numeric) ? @smoothing_setting : DEFAULT_SMOOTHING_RATE) if @smooth_limit

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
          @smoothing_setting = smoothing

          if smoothing.respond_to?(:process) && smoothing.respond_to?(:reset)
            check_rate(smoothing, 'smoothing')
            @filter = smoothing
            @smooth_limit = nil
          else
            new_limit = @sample_rate * (smoothing.is_a?(Numeric) ? smoothing : DEFAULT_SMOOTHING_RATE)
            if new_limit != @smooth_limit
              @smooth_limit = new_limit
              @filter = MB::Sound::DelayLine.smoother(smoothing || true, @sample_rate)
            end
          end

          reset_delay
        end

        # Sets the delay time: a number of seconds, a length (`5.samples`,
        # `250.ms`, `0.01.seconds`), a Duration that follows the tempo
        # (`3.n16`), or a graph node giving the time every sample (seconds,
        # or samples with `node.samples`; musical-time nodes such as
        # `2.bars.lfo.at(3.n16..5.n16)` follow the tempo).  The time keeps
        # its unit and converts to samples as the delay runs, at the sample
        # rate of that moment.  Fractional sample counts are kept (and
        # interpolated); counts within a billionth of a whole sample snap to
        # it (see MB::Sound::Length.snap).  Smoothing glides to the new time.
        def delay=(time)
          @delay = time
          @time = MB::Sound::Length::Source.new(time)
          check_rate(@time.node, 'delay') if @time.node?

          if @time.node?
            @min_delay_samples = @max_delay_samples = @last_delay_samples = 0
          else
            @min_delay_samples = @max_delay_samples = @last_delay_samples = @time.constant_samples(@sample_rate)
          end

          # Start a tempo-synced delay at its time (at the current tempo, and
          # again when a Session starts it) instead of gliding up from zero
          if (tempo = @time.tempo_node)
            reset_delay(tempo.value * @sample_rate)
            tempo.on_start { |n| reset_delay(n.value * @sample_rate) }
          end
        end

        # Sets the delay time in samples at the delay's sample rate (a number
        # or a graph node); the same as `delay = samples.samples`.
        def delay_samples=(samples)
          self.delay = samples.is_a?(MB::Sound::Length) ? samples : MB::Sound::Length::Samples.new(samples)
        end

        # Sets the interpolation mode for fractional delays (:linear, :cubic,
        # or :sinc; see MB::Sound::DelayLine).
        def interpolation=(mode)
          unless MB::Sound::DelayLine::INTERPOLATION.include?(mode)
            raise ArgumentError, "Unknown interpolation #{mode.inspect} (use one of #{MB::Sound::DelayLine::INTERPOLATION.keys.join(', ')})"
          end
          @interpolation = mode
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
          (@time.node? ? { delay: @time.node } : {}).merge(
            { wet: @wet, dry: @dry }.select { |_, v| v.respond_to?(:sample) }
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
          else
            data = data[0...delays.length] if data.length > delays.length
            delays = delays[0...data.length] if delays.length > data.length
            @min_delay_samples, @max_delay_samples = delays_minmax(delays)
            @last_delay_samples = delays[-1]
            max_delay = @max_delay_samples
          end

          wet = control_values(@wet, data.length)
          dry = control_values(@dry, data.length)
          return nil if wet.nil? || dry.nil?

          # (the shortest input, without Arrays)
          length = data.length
          length = wet.length if wet.respond_to?(:length) && wet.length < length
          length = dry.length if dry.respond_to?(:length) && dry.length < length
          if length < data.length
            data = data[0...length]
            delays = delays[0...length] if delays.respond_to?(:length)
          end

          @line.prepare(data.length, max_delay, complex_value?(data) ? Numo::SComplex : data.class)
          @line.write(data)
          @read_buf = @line.buffer_class.zeros(data.length) unless @read_buf && @read_buf.class == @line.buffer_class && @read_buf.length == data.length
          delayed = @line.read(data.length, delays, interpolation: @interpolation, state: @read_state, out: @read_buf)

          # Numeric gains on SFloat buffers: the same products and sum in
          # one allocation-free pass, into the input (as below) or a reused
          # buffer
          if wet.is_a?(Numeric) && dry.is_a?(Numeric) && data.length == length
            target = data.inplace? && !data.frozen? ? data : (@result_buf = reuse_buffer(@result_buf, data))
            return target if target && MB::Sound::Kernels.wet_dry(target, delayed, wet, data, dry != 0 ? dry : nil)
          end

          # Moving gains on SFloat buffers: the same products and sums in
          # reused buffers (dropouts-2: a moving wet was ~640 KB/s of
          # garbage in night_bus_flow)
          if (r = gains_reused(data, delayed, wet, dry, length))
            return r
          end

          result = wet.is_a?(Numo::NArray) ? delayed * wet[0...length] : wet * delayed
          if dry.is_a?(Numo::NArray)
            result = result + data * dry[0...length]
          elsif dry != 0
            result = result + dry * data
          end

          if data.inplace? && !data.frozen?
            data[true] = result
            data
          else
            result
          end
        end

        # Rings out after the input ends (called by SampleWrapper in place of
        # #process once its source ends): processes +count+ samples of
        # silence and returns the output, shortened to end on the exact
        # sample where the delay line has held only silence (below -90 dB,
        # see MB::Sound::QuietRun#advance) for the longest delay plus the
        # interpolation reach, then nil: the delay plays its last echo.
        def ring_out(count)
          @ring ||= MB::Sound::QuietRun.new(0) # (the ring-out form: QuietRun#advance)
          return nil if @ring.done?

          @ring_zeros = Numo::SFloat.zeros(count) if @ring_zeros.nil? || @ring_zeros.length != count
          @ring_zeros.fill(0)
          out = process(@ring_zeros)
          return nil if out.nil?

          # The delay line now holds only silence (the input is silent)
          window = (@max_delay_samples.to_f.finite? ? @max_delay_samples.to_f.ceil : 0) + MB::Sound::DelayLine::MARGIN
          keep = @ring.advance(nil, out.length, window)
          keep && keep < out.length ? out[0...keep] : out
        end

        # True if the delay rings out after its input ends (the default; see
        # #ring_out), false if it ends with its input.
        def rings_out?
          @ring_out
        end

        # True once #ring_out has played the whole tail.
        def rung_out?
          !!@ring&.done?
        end

        def response
          raise NotImplementedError, 'TODO: return a phase value based on the delay'
        end

        def to_s
          "Delay -- interpolation=#{@interpolation} smoothing=#{@smoothing} smooth_limit=#{@smooth_limit} dry=#{level(@dry)} wet=#{level(@wet)}"
        end

        def to_s_graphviz
          "Delay\ninterpolation: #{@interpolation}\nsmoothing: #{@smoothing}\nsmooth_limit: #{@smooth_limit}\ndry: #{level(@dry)}\nwet: #{level(@wet)}"
        end

        private

        # A reused SFloat buffer as long as +data+ (an SFloat), or nil.
        # #process's wet * delayed + dry * data (gains Numerics or SFloats
        # as long as the block) in reused SFloats, or nil for other types.
        def gains_reused(data, delayed, wet, dry, length)
          return nil unless data.is_a?(Numo::SFloat) && delayed.is_a?(Numo::SFloat) && data.length == length && delayed.length == length
          return nil unless (wet.is_a?(Numeric) || (wet.is_a?(Numo::SFloat) && wet.length == length)) &&
                            (dry.is_a?(Numeric) || (dry.is_a?(Numo::SFloat) && dry.length == length))
          return nil if wet.is_a?(Numeric) && !wet.real?
          return nil if dry.is_a?(Numeric) && !dry.real?

          # (Kernels.scale and .accumulate: the same float steps as
          # Numo's, without its temporaries)
          r = @result_buf = reuse_buffer(@result_buf, data)
          return nil unless MB::Sound::Kernels.copy(r, delayed) && MB::Sound::Kernels.scale(r, wet)
          if dry.is_a?(Numo::NArray) || dry != 0
            r.inplace + data * dry unless length == 0 || MB::Sound::Kernels.accumulate(r, 0, data, 0, length, dry, 0, nil, 0)
          end
          return r unless data.inplace? && !data.frozen?

          data[true] = r unless MB::Sound::Kernels.copy(data, r)
          data
        end

        def reuse_buffer(buf, data)
          return nil unless data.is_a?(Numo::SFloat)
          buf && buf.length == data.length ? buf : Numo::SFloat.zeros(data.length)
        end

        # delays.minmax, as Floats, without allocating for real buffers
        # (Kernels.min_max matches Numo's minmax except for all-NaN
        # buffers, which take Numo's path).
        def delays_minmax(delays)
          r = (@delay_range ||= [0.0, 0.0])
          if MB::Sound::Kernels.min_max(delays, r) && !r[0].nan?
            return r
          end
          delays.minmax
        end

        # Checks a wet/dry value: a graph node (sampled per buffer, through
        # get_sampler) or a number.
        def control(value, name)
          if value.respond_to?(:sample)
            value = value.get_sampler
            check_rate(value, name)
            value
          elsif value.nil? || value == false
            raise ArgumentError, "#{name} must be a number or a graph node"
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

        # True for complex buffers and numbers (see #process).
        def complex_value?(v)
          v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex) || v.is_a?(Complex)
        end

        # Returns the delay in samples for each of +count+ samples (smoothed
        # if smoothing is on), a Numeric delay for every sample, or :end if
        # the delay time node ended.
        #
        # Once the default smoothing (a LinearFollower) has reached a
        # constant target, the filter is skipped (it would output the
        # target unchanged), so settled delays read as constant delays.
        def delay_buffer(count)
          settled = @smoothing && @filter.is_a?(MB::Sound::Filter::LinearFollower)

          if @time.node?
            # TODO: maybe upstream sampling should be moved to SampleWrapper
            # and we should use a dynamic_process method for processing with
            # multiple inputs
            delays = @time.samples(count, @sample_rate)
            return :end if delays.nil?

            if @seed_node
              # The smoothed delay starts at the node's first value (see
              # #reset_delay)
              @seed_node = false
              @filter.reset(delays[0]) if @smoothing && count > 0
            end

            if settled
              min, max = MB::Sound::Kernels.min_max(delays, @minmax) || delays.minmax
              return apply_loop_offset(min.to_f) if min == max && min == @filter.peek
            end
          else
            target = @time.constant_samples(@sample_rate)
            return apply_loop_offset(target) if !@smoothing || (settled && @filter.peek == target)

            @filter_buf = Numo::SFloat.zeros(count) if @filter_buf.length < count
            delays = @filter_buf[0...count].fill(target)
          end

          if @smoothing
            delays = (@frozen_copy ||= GraphNode::FrozenCopy.new).copy(delays) if delays.frozen? # a shared buffer (see GraphNode::Tee)
            delays = @filter.process(delays.inplace).not_inplace!
          end
          apply_loop_offset(delays)
        end

        # Subtracts #loop_offset from +delays+ (a Numeric or an NArray).
        def apply_loop_offset(delays)
          off = @loop_offset
          return delays if off.nil? || off == 0

          delays.is_a?(Numo::NArray) ? Numo::DFloat.cast(delays) - off : delays - off
        end
      end
    end
  end
end
