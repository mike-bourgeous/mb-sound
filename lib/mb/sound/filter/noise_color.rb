module MB
  module Sound
    class Filter
      # Colors white noise (textures-4, 2026-10-15): :pink falls 3 dB per
      # octave (equal power per octave), :brown (alias :red) 6 dB per octave
      # (a leaky integrator, like a random walk).  Used by
      # MB::Sound.noise(:pink); any signal may go through it
      # (`sig.filter(Filter::NoiseColor.new(:pink))` tilts it).
      #
      # Pink: alternating first-order poles and zeros (a zero half a step
      # above each pole, poles 2.6x apart from 9.1 Hz up to the sample
      # rate's top), bilinear-transformed and paired into biquads: within
      # +-0.17 dB of an exact -3 dB/octave slope from 20 Hz to 20 kHz at 48
      # kHz (+-0.23 dB at 44.1 kHz), flat below about 9 Hz.  Brown: one pole
      # at 5 Hz (flat below it, so it never wanders off to DC), within 1 dB
      # of -6 dB/octave to 12 kHz.
      #
      # The gain makes white noise with the RMS of MB::Sound.noise (uniform
      # -1..1, RMS 0.577) come out at RMS 0.2 (-14 dBFS): Gaussian-like
      # peaks pass full scale about once per 1.7 million samples (35 s).
      class NoiseColor < Filter
        node_traits memory: :short

        COLORS = [:pink, :brown].freeze
        ALIASES = { red: :brown }.freeze

        # Pink design: first pole (Hz) and the ratio between poles.
        PINK_FIRST_POLE = 9.1
        PINK_RATIO = 2.6

        # Brown design: the pole (Hz).
        BROWN_POLE = 5.0

        # Output RMS for white noise of RMS WHITE_RMS.
        TARGET_RMS = 0.2
        WHITE_RMS = 1.0 / Math.sqrt(3)

        attr_reader :color, :sample_rate

        def initialize(color = :pink, sample_rate: 48000)
          c = ALIASES.fetch(color, color)
          raise ArgumentError, "Unknown noise color #{color.inspect} (#{(COLORS + ALIASES.keys).map(&:inspect).join(', ')})" unless COLORS.include?(c)

          @color = c
          self.sample_rate = sample_rate
        end

        # Redesigns the filter for +rate+ (state reset).
        def sample_rate=(rate)
          @sample_rate = rate.to_f
          @chain = Filter::FilterChain.new(*design)
          @gain = TARGET_RMS / (WHITE_RMS * Math.sqrt(energy))
        end
        alias at_rate sample_rate=

        def process(data)
          out = @chain.process(data)
          out.inplace? ? (out.inplace * @gain) : out * @gain
        end

        def reset(value = 0)
          @chain.reset(value)
          value
        end

        # Complex response at angular frequency +omega+ (radians per sample).
        def response(omega)
          @chain.response(omega) * @gain
        end

        def to_s
          "#{@color} noise color"
        end

        private

        # Biquads for the color (unnormalized).
        def design
          if @color == :brown
            # A plain one-pole leaky integrator (matched z): within 1 dB of
            # 6 dB/octave up to 12 kHz at 48 kHz, where the bilinear form's
            # zero at Nyquist would fall 2 dB short.
            p = Math.exp(-2 * Math::PI * BROWN_POLE / @sample_rate)
            return [Filter::Biquad.new(1.0, 0.0, 0.0, -p, 0.0, sample_rate: @sample_rate)]
          end

          poles, zeros = pole_zero
          bl = ->(f) { w = Math.tan(Math::PI * f / @sample_rate); (1 - w) / (1 + w) }
          pz = poles.map(&bl)
          zz = zeros.map(&bl)
          pz.each_slice(2).zip(zz.each_slice(2)).map { |p, z|
            Filter::Biquad.from_pole_zero(poles: p, zeros: z, sample_rate: @sample_rate)
          }
        end

        # Pink's analog poles and zeros in Hz.
        def pole_zero
          poles = []
          k = 0
          while (p = PINK_FIRST_POLE * PINK_RATIO**k) * Math.sqrt(PINK_RATIO) < @sample_rate * 0.49
            poles << p
            k += 1
          end
          [poles, poles.map { |p| p * Math.sqrt(PINK_RATIO) }]
        end

        # Energy (sum of squares) of the unnormalized impulse response.
        def energy
          len = (@sample_rate * 2).ceil # the slowest pole decays 60+ dB within 2 s
          imp = Numo::DFloat.zeros(len)
          imp[0] = 1
          h = @chain.process(imp)
          @chain.reset(0)
          (h * h).sum
        end
      end
    end
  end
end
