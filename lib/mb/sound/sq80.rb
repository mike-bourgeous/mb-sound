module MB
  module Sound
    # Ensoniq SQ-80 flavored helpers: panel units (0..63 times, -63..+63
    # levels) converted to mb-sound's units, for building SQ-80-style voices
    # out of the library's general pieces (multi-segment envelopes, LFOs,
    # modulation sums, poly pressure).  A full patch model (SysEx import)
    # may live here later.
    #
    # Sources: the SQ-80 Musician's Manual (time chart, envelope pages); see
    # research/sq80/README.md on the research-sq80 branch.  Values marked
    # UNVERIFIED there (second release level and rate, velocity curves, TK
    # scaling) are by ear until they can be measured on a real unit.
    module SQ80
      # The manual's envelope time chart: panel value => seconds (TK = 0,
      # T1V = 0).  Values between points are interpolated geometrically
      # (time grows by a constant ratio per step), and 0 is instant.
      TIME_POINTS = {
        1 => 0.01, 8 => 0.04, 12 => 0.06, 16 => 0.09, 24 => 0.23, 28 => 0.36, 30 => 0.45, 32 => 0.57,
        40 => 1.44, 44 => 2.28, 46 => 2.87, 48 => 3.62, 56 => 9.12, 60 => 14.48, 63 => 20.48,
      }.freeze

      # The level (relative to the release's start level, L3) that a second
      # release (T4 "R" values) falls to over T4 before fading out over
      # SECOND_RELEASE_TIME (UNVERIFIED: chosen by ear, about -18 dB).
      SECOND_RELEASE_LEVEL = 0.125

      # Seconds the second release takes to fade from SECOND_RELEASE_LEVEL to
      # 0 (UNVERIFIED: "a fixed rate" in the manual; chosen by ear).
      SECOND_RELEASE_TIME = 2.5

      # The quietest velocity gain of an exponential (X) LV setting of 63,
      # in dB (UNVERIFIED).
      LV_EXP_RANGE_DB = 40.0

      # Curves (dB, see Envelope) used by .env_options unless +:curve+ is
      # given: the SQ-80's segment shapes are unverified (and its ~83 Hz
      # control rate smooths them), so a gentle curve that sounds natural
      # through a linear VCA.
      DEFAULT_CURVE = :gentle

      # Returns the envelope time in seconds for a panel value 0..63 (may be
      # fractional).
      def self.time(value)
        v = value.to_f
        raise ArgumentError, "SQ-80 times are 0..63 (got #{value.inspect})" unless v >= 0 && v <= 63
        return 0.0 if v == 0
        return TIME_POINTS[1] * v if v < 1

        (lo, tlo), (hi, thi) = TIME_POINTS.each_cons(2).find { |(a, _), (b, _)| v >= a && v <= b }
        tlo * (thi / tlo) ** ((v - lo) / (hi - lo).to_f)
      end

      # Returns a level -1..1 for a panel level -63..+63.
      def self.level(value)
        v = value.to_f
        raise ArgumentError, "SQ-80 levels are -63..+63 (got #{value.inspect})" unless v >= -63 && v <= 63
        v / 63.0
      end

      # Returns Envelope options (+:segments+, +:release_at+, +:loop+,
      # +:hold+, +:sensitivity+, +:velocity_scale+, +:curve+) for SQ-80
      # panel values:
      #
      # +l1+, +l2+, +l3+ - Levels -63..+63 (L3 is the sustain level).
      # +t1+..+t4+ - Times 0..63 (T4 is the release, from the current level
      #              to 0).
      # +lv+ - Velocity to every level, 0..63 (0: none).
      # +lv_curve+ - :linear (the panel's "L") or :exp ("X"; velocity in dB).
      # +t1v+ - Velocity shortening T1, 0..63 (63: no attack at full
      #         velocity); needs a +velocity+ node.
      # +tk+ - Keyboard shortening T2 and T3, 0..63 (63: halved per octave
      #        above C4, doubled per octave below; UNVERIFIED scaling); needs
      #        a +key+ node (note numbers).
      # +second_release+ - True for the SQ-80's T4 "R" values: the release
      #                    falls to SECOND_RELEASE_LEVEL of L3 over T4, then
      #                    fades out over SECOND_RELEASE_TIME (a pseudo
      #                    reverb).
      # +cycle+ - True for CYC mode: every stage runs and the key-up is
      #           ignored (T3 runs straight into T4).  Use with a trigger
      #           and no gate (Notes#sq80_env does).
      # +loop+ - An extension: a segment index or name (:t1..:t3) to jump back
      #          to after T3 while the key is held (true: T1), so the
      #          envelope repeats as a rhythmic modulator.
      # +curve+ - Envelope curves (default DEFAULT_CURVE).
      def self.env_options(
        l1: 63, l2: 63, l3: 63, t1: 0, t2: 0, t3: 0, t4: 0,
        lv: 0, lv_curve: :linear, t1v: 0, tk: 0,
        second_release: false, cycle: false, loop: nil, curve: DEFAULT_CURVE,
        velocity: nil, key: nil
      )
        raise ArgumentError, 'Give cycle: or loop:, not both' if cycle && loop

        times = [t1, t2, t3, t4].map { |t| time(t) }
        times[0] = scaled_time(times[0], velocity, t1v / 63.0, :velocity) unless t1v == 0
        unless tk == 0
          times[1] = scaled_time(times[1], key, tk / 63.0, :key)
          times[2] = scaled_time(times[2], key, tk / 63.0, :key)
        end

        levels = [l1, l2, l3].map { |l| level(l) }
        segments = levels.zip(times).map { |l, t| [l, t] }
        if second_release
          segments << [levels[2] * SECOND_RELEASE_LEVEL, times[3]]
          segments << [0.0, SECOND_RELEASE_TIME]
        else
          segments << [0.0, times[3]]
        end

        options = {
          segments: segments,
          release_at: 3,
          curve: curve,
          **velocity_options(lv, lv_curve),
        }
        options[:loop] = 3 if cycle
        options[:loop] = loop == true ? 0 : loop if loop
        options[:hold] = false if cycle || loop
        options
      end

      # Envelope velocity options for an LV amount (0..63) and curve.
      def self.velocity_options(lv, curve)
        amount = lv / 63.0
        raise ArgumentError, "LV must be 0..63 (got #{lv.inspect})" unless amount >= 0 && amount <= 1

        case curve
        when :linear, :lin, :l
          { sensitivity: (1.0 - amount)..1.0, velocity_scale: :linear }
        when :exp, :exponential, :x
          { sensitivity: (10.0 ** (-LV_EXP_RANGE_DB * amount / 20.0))..1.0, velocity_scale: :db }
        else
          raise ArgumentError, "LV curve must be :linear or :exp (got #{curve.inspect})"
        end
      end

      # A time node: +seconds+ shortened by +amount+ (0..1) of the +source+
      # node (see TimeScale).
      def self.scaled_time(seconds, source, amount, kind)
        raise ArgumentError, "SQ-80 #{kind} time scaling needs a #{kind} node (#{kind}:)" unless source.respond_to?(:sample)
        return seconds if seconds == 0

        TimeScale.new(seconds, source, kind, amount)
      end

      # An envelope time in seconds scaled by a control: +:velocity+ gives
      # seconds × (1 - amount × velocity) (T1V), +:key+ seconds × 2 **
      # (-amount × (note - 60) / 12) (TK).  The controls (Notes velocity
      # and note number) hold still between notes, so while the source
      # returns the same frozen constant buffer this returns one frozen
      # constant buffer too (computed once per value), which envelopes
      # take without copying.
      class TimeScale
        include GraphNode
        include GraphNode::SampleRateHelper

        KINDS = [:velocity, :key].freeze

        attr_reader :seconds, :source, :kind, :amount

        def initialize(seconds, source, kind, amount, sample_rate: 48000)
          raise ArgumentError, "Time scale kind must be one of #{KINDS} (got #{kind.inspect})" unless KINDS.include?(kind)

          @seconds = seconds.to_f
          @source = source.get_sampler
          @kind = kind
          @amount = amount.to_f
          @sample_rate = sample_rate.to_f
          @buf = nil
          @steady = nil
          @steady_in = nil
          @node_type_name = "SQ-80 #{kind} time"
        end

        def sample(count)
          s = @source.sample(count)
          return nil if s.nil?
          return @steady if s.equal?(@steady_in) && @steady && @steady.length == s.length

          if s.frozen? && (v = s[0]) == s.max && v == s.min
            value = time(v)
            @steady = @steady && @steady.length == s.length && @steady_value == value ? @steady : Numo::SFloat.new(s.length).fill(value).freeze
            @steady_value = value
            @steady_in = s
            return @steady
          end

          @steady_in = nil
          @buf = Numo::SFloat.zeros(s.length) if @buf.nil? || @buf.length != s.length
          @buf[0..] = s.to_a.map { |x| time(x) }
          @buf
        end

        # The scaled time for a control value +v+.
        def time(v)
          case @kind
          when :velocity then @seconds * (1.0 - @amount * v)
          else @seconds * 2.0 ** (-@amount * (v - 60.0) / 12.0)
          end
        end

        def sources
          { @kind => @source }
        end

        def to_s
          "#{@node_type_name} #{MB::M.sigfigs(@seconds, 4)} s"
        end
      end

      private_class_method :scaled_time
    end
  end
end
