module MB
  module Sound
    module GraphNode
      # Amplitude modulation (tremolo): multiplies its input by a gain that a
      # modulator moves between unity (modulator at +1) and a trough set by
      # +depth+ (modulator at -1).  The modulator is any node in -1..1,
      # usually an LFO Tone (TremoloMethods#tremolo builds it from the
      # library's LFO shapes, tempo-synced rates, or a drawn wavetable).
      #
      # +depth+ is how far the trough goes down, read like a ducking amount
      # (Decibels.reduction_db): -12.db and 12.db both mean 12 dB down, a bare
      # number is the trough's linear gain (0.25 is 12 dB down, 0 a full
      # cut), (-Float::INFINITY).db a full cut too.  A node gives the trough's
      # linear gain per sample (0..1).
      #
      # +law+ is how the gain moves between unity and the trough:
      # - :db (default): evenly in dB (gain dB = depth dB x (1 - m) / 2), as
      #   Sony's Amplitude Modulation does; a trough deeper than +floor+
      #   (default -80 dB, where Sony puts an amplitude of -inf) stops there.
      # - :linear: evenly in amplitude (gain = 1 - (1 - trough) x (1 - m) /
      #   2), the classic tremolo; a full cut reaches silence.
      #
      # The modulator is clamped to -1..1 (a band-limited square's ripple
      # never lifts the gain above unity).  Ends when the input or the
      # modulator ends.
      #
      #     play 220.hz.saw.at(-12.db).tremolo(5, depth: 12.db)
      class Tremolo
        include GraphNode
        include SampleRateHelper
        # (a gain computed from its inputs: no running state)
        node_traits memory: :none

        # Gain laws (see the class description).
        LAWS = %i[db linear].freeze

        # The default deepest trough of the :db law (Sony Amplitude
        # Modulation's amplitude of -inf, measured on its renders).
        DEFAULT_FLOOR = -80.0

        # The law (:db or :linear).
        attr_reader :law

        # The trough's reduction in dB (Float, Infinity for a full cut), or
        # nil when the depth is a node.
        attr_reader :depth_db

        # The :db law's deepest trough in dB (a negative Float).
        attr_reader :floor_db

        # +input+ is the signal, +modulator+ a node in -1..1 (see the class
        # description for +depth+, +law+, and +floor+).
        def initialize(input, modulator, depth: 12.db, law: :db, floor: DEFAULT_FLOOR.db)
          raise ArgumentError, 'Tremolo input must respond to #sample' unless input.respond_to?(:sample)
          raise ArgumentError, "Tremolo modulator must be a graph node (got #{modulator.inspect})" unless modulator.respond_to?(:sample)
          raise ArgumentError, "tremolo law: is #{LAWS.map(&:inspect).join(' or ')} (got #{law.inspect})" unless LAWS.include?(law)

          @input = input.get_sampler
          @modulator = modulator.get_sampler
          @law = law
          @floor_db = -Decibels.reduction_db(floor, 'floor')
          raise ArgumentError, "tremolo floor: must be below 0 dB and finite (got #{floor.inspect})" unless @floor_db < 0 && @floor_db.finite?

          if depth.respond_to?(:sample)
            @depth = depth.get_sampler
            @depth_db = nil
          else
            @depth = nil
            @depth_db = Decibels.reduction_db(depth, 'depth')
          end
          @sample_rate = @input.sample_rate.to_f
          @copier = FrozenCopy.new
          @gain = nil
          @node_type_name = 'Tremolo'
        end

        # The input, the modulator, and the depth (if a node).
        def sources
          @depth ? { input: @input, modulator: @modulator, depth: @depth } : { input: @input, modulator: @modulator }
        end

        # The trough's linear gain (Float) for a numeric depth, as the law
        # reaches it (the :db law stops at its floor).
        def trough
          return nil if @depth_db.nil?
          return 0.0 if @law == :linear && @depth_db.infinite?

          db = @law == :db ? MB::M.min(@depth_db, -@floor_db) : @depth_db
          10.0 ** (-db / 20.0)
        end

        def sample(count)
          x = @input.sample(count)
          return nil if x.nil? || x.empty?

          m = @modulator.sample(x.length)
          return nil if m.nil? || m.empty?

          d = nil
          if @depth
            d = @depth.sample(x.length)
            return nil if d.nil? || d.empty?
          end

          n = MB::M.min(x.length, m.length)
          n = MB::M.min(n, d.length) if d
          x = x[0...n] if x.length != n

          g = gain(m, d, n)
          x = @copier.copy(x) if x.frozen?
          x.inplace!
          (x * g).not_inplace!
        end

        # The gain for modulator samples +m+ (and depth samples +d+, or
        # nil for a numeric depth), +n+ of them, in a reused SFloat buffer.
        # Also the reference the specs check the formula with.
        def gain(m, d, n)
          @gain = Numo::SFloat.zeros(n) if @gain.nil? || @gain.length != n
          g = @gain
          g[0...n] = m.length == n ? m : m[0...n]
          g.inplace!
          # u: 0 at the top of the modulator, 1 at its bottom
          g.clip(-1, 1)
          g * -0.5
          g + 0.5

          if d.nil?
            t = trough
            if @law == :db
              Numo::NMath.exp(g * Math.log(t))
            else
              g * -(1 - t)
              g + 1
            end
          else
            t = Numo::SFloat.cast(d.length == n ? d : d[0...n]).clip(0, 1)
            if @law == :db
              t = t.clip(10.0 ** (@floor_db / 20.0), 1)
              Numo::NMath.exp(g * Numo::NMath.log(t))
            else
              g * (t - 1)
              g + 1
            end
          end
          g.not_inplace!
        end

        def to_s
          depth = @depth_db.nil? ? 'depth node' : (@depth_db.infinite? ? '-inf dB' : "-#{MB::M.sigfigs(@depth_db, 4)} dB")
          "#{super} -- #{depth}, #{@law}"
        end
      end
    end
  end
end
