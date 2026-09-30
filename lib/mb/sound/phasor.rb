module MB
  module Sound
    # A phase accumulator: outputs the phase of a cycle at +frequency+, in
    # cycles (0 <= phase < 1), for driving waveform shapers (Oscillator
    # waves, wavetables).  The output buffer is single precision, while the
    # phase itself is kept in double precision so it doesn't drift.
    #
    # Each sample the phase advances by frequency * (advance + random *
    # random_advance), where +advance+ and +random_advance+ are in cycles per
    # Hz (+advance+ is normally 1 / sample_rate) and random is uniform in
    # 0..1.  A nonzero +random_advance+ jitters the phase (Tone#noise).
    #
    # #sample uses C (MB::FastSound.phasor); #sample_ruby is the equivalent
    # in Ruby (vectorized with Numo), checked against it by the specs.
    # Oscillator keeps its phase in a Phasor and runs phasor and shaper in
    # one C loop (MB::FastSound.oscillate).
    #
    # Example (bin/sound.rb):
    #     plot 100.hz.phasor, samples: 1000
    class Phasor
      include GraphNode

      RAND = ENV['RANDOM_SEED'] ? Random.new(Integer(ENV['RANDOM_SEED'])) : Random.new

      # The frequency source (a Numeric in Hz, or a node's sampler).
      attr_reader :frequency

      # The starting phase in cycles (see #reset).
      attr_reader :phase

      # Cycles per Hz per sample (normally 1 / sample_rate), and the
      # maximum random addition to it (see the class description).
      attr_reader :advance, :random_advance

      # The sample rate (from #advance, or set with #sample_rate=).
      attr_reader :sample_rate

      # The state passed to the C code: [current phase in cycles].
      attr_reader :state

      # Creates a phasor at +frequency+ (Hz, or a node) starting at +phase+
      # (cycles).  +advance+ defaults to 1 / +sample_rate+.
      def initialize(frequency: 1.0, phase: 0.0, sample_rate: 48000, advance: nil, random_advance: 0.0)
        raise "Invalid phase #{phase.inspect}" unless phase.is_a?(Numeric)

        self.frequency = frequency
        @sample_rate = sample_rate.to_f
        @advance = (advance || 1.0 / @sample_rate).to_f
        @random_advance = random_advance.to_f
        @phase = phase % 1.0
        @state = [@phase.to_f]
        @buf = nil
      end

      # Changes the frequency source to a Numeric (Hz) or a node.
      def frequency=(frequency)
        unless frequency.is_a?(Numeric) || frequency.respond_to?(:sample) || frequency.respond_to?(:get_sampler)
          raise "Invalid frequency #{frequency.inspect}"
        end

        frequency = frequency.get_sampler if frequency.respond_to?(:get_sampler)
        @frequency = frequency
      end

      # Sets the per-sample advance in cycles per Hz (see the class
      # description).
      def advance=(advance)
        @advance = advance.to_f
      end

      # Sets the random addition to the advance in cycles per Hz.
      def random_advance=(random_advance)
        @random_advance = random_advance.to_f
      end

      # Changes the sample rate, setting #advance to 1 / +sample_rate+.
      def sample_rate=(sample_rate)
        @sample_rate = sample_rate.to_f
        @advance = 1.0 / @sample_rate
        self
      end
      alias at_rate sample_rate=

      # The current phase in cycles.
      def phi
        @state[0]
      end

      # Sets the current phase in cycles (wrapped to 0...1).
      def phi=(phi)
        @state[0] = (phi % 1.0).to_f
      end

      # Changes the starting phase (cycles), shifting the current phase by
      # the same amount.
      def phase=(phase)
        self.phi = phi + phase - @phase
        @phase = phase % 1.0
      end

      # Moves the phase to the starting phase (see #phase).
      def reset
        self.phi = @phase
        self
      end

      # Moves the phase to +cycles+ past the starting phase (e.g. to lock an
      # LFO to a timeline position; see Sequence::TempoNode).
      def sync(cycles)
        self.phi = @phase + cycles
        self
      end

      def sources
        { frequency: @frequency }
      end

      # Returns +count+ phases (cycles) as an SFloat NArray (reused between
      # calls), or nil once the frequency source ends.
      def sample(count)
        sample_c(count)
      end

      # C implementation of #sample.
      def sample_c(count)
        freq = sample_frequency(count)
        return nil if freq.nil?

        count = freq.length if freq.is_a?(Numo::NArray)
        phases_c(freq, count)
      end

      # Ruby implementation of #sample.
      def sample_ruby(count)
        freq = sample_frequency(count)
        return nil if freq.nil?

        count = freq.length if freq.is_a?(Numo::NArray)
        Numo::SFloat.cast(phases_ruby(freq, count)[0])
      end

      # Advances the phase over +count+ samples at +freq+ (Hz; a Numeric or
      # an NArray of +count+ values) in C, returning the phases in an SFloat
      # NArray (reused between calls).
      def phases_c(freq, count)
        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
        MB::FastSound.phasor(@buf.inplace!, freq, @advance, @random_advance, @state, nil).not_inplace!
      end

      # Advances the phase over +count+ samples at +freq+ (Hz; a Numeric or
      # an NArray of +count+ values) in Ruby, returning [phases, increments]
      # as DFloat NArrays (increments is a Float if every sample advances by
      # the same amount).  The same math as MB::FastSound.phasor: phase[i] =
      # phi + sum(increments[0...i]) (i * increment when constant), wrapped
      # once to 0...1.
      def phases_ruby(freq, count)
        freq = Numo::DFloat.cast(freq) if freq.is_a?(Numo::NArray)

        if @random_advance != 0
          random = Numo::DFloat.cast(Array.new(count) { RAND.rand })
          increments = freq * (random * @random_advance + @advance)
        else
          increments = freq * @advance
        end

        if increments.is_a?(Numo::NArray)
          # Running sum: phase i has advanced by increments 0...i
          sums = increments.cumsum
          steps = Numo::DFloat.zeros(count)
          steps[1..] = sums[0...-1] if count > 1
          total = sums[-1]
        else
          steps = Numo::DFloat.new(count).seq * increments
          total = increments * count
        end

        phases = steps + phi
        phases -= phases.floor # like Ruby's %, not Numo's (which keeps the sign)
        self.phi = phi + total

        [phases, increments]
      end

      private

      # Returns the frequency for +count+ samples: a Numeric, an NArray (maybe
      # shorter at the end of its source), or nil if the source ended.
      def sample_frequency(count)
        return @frequency unless @frequency.respond_to?(:sample)

        freq = @frequency.sample(count)
        freq.nil? || freq.empty? ? nil : freq
      end
    end
  end
end
