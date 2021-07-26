module MB
  module Sound
    # A delay-based panner.  Delays the right speaker to shift sounds to the
    # left, delays the left speaker to shift sounds to the right.
    class HaasPan
      # Delay in seconds.  Positive values delay the right channel, negative
      # values delay the left channel.
      attr_reader :delay

      # Delay in samples.  Positive values delay the right channel, negative
      # values delay the left channel.
      attr_reader :delay_samples

      # Sample rate given to the constructor.
      attr_reader :rate

      # Initializes a HaasPan with the given +:delay+ in seconds, and the given
      # sample +:rate+.
      def initialize(delay: 0, rate: 48000)
        @rate = rate.to_f
        self.delay = delay

        # Two separate delays are needed, because of delay smoothing.  Without
        # delay smoothing only one delay object could be used.
        @left_delay = MB::Sound::Filter::Delay.new(delay: @delay > 0 ? 0 : @delay, rate: rate, smoothing: true)
        @right_delay = MB::Sound::Filter::Delay.new(delay: @delay > 0 ? @delay : 0, rate: rate, smoothing: true)
      end

      # Sets the delay time in +samples+, rounded to the nearest Integer,
      # regardless of sample rate.  Positive values delay the right channel,
      # negative values delay the left channel.
      def delay_samples=(samples)
        @delay_samples = samples.round
        @delay = @delay_samples.to_f / @rate
      end

      # Sets the delay time in +seconds+, based on sample rate.  Delay time
      # will be rounded to the nearest sample.  Positive values delay the right
      # channel, negative values delay the left channel.
      def delay=(seconds)
        self.delay_samples = seconds * @rate
      end

      # Processes one or two channels of data, returning two channels with the
      # relative delay specified by #delay.
      def process(data)
        data = [data, data.dup] if data.is_a?(Numo::NArray)
        data = [data[0], data[0].dup] if data.is_a?(Array) && data.length == 1
        raise 'Pass one or two channels to #process' if data.length != 2

        if @delay_samples >= 0
          @left_delay.delay_samples = 0
          @right_delay.delay_samples = @delay_samples
        else
          @left_delay.delay_samples = @delay_samples.abs
          @right_delay.delay_samples = 0
        end

        l = @left_delay.process(data[0])
        r = @right_delay.process(data[1])

        [l, r]
      end
    end
  end
end
