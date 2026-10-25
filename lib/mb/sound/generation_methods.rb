module MB
  module Sound
    # Methods to help generating sounds, either as source GraphNodes or as an
    # Array of Numo::NArrays.
    #
    # Included in MB::Sound for the bin/sound.rb DSL.
    module GenerationMethods
      # Creates a uniformly distributed white noise generator that can be
      # combined with other tones, filters, etc.  See MB::Sound::GraphNode
      # and MB::Sound::Tone.  Each call gives a new random stream, seeded
      # with +seed+ or a sub-seed from the root generator (see
      # MB::Sound.seed and Tone#noise), so renders repeat.
      #
      # +color+ :pink (3 dB quieter each octave up: equal power per octave,
      # softer and easier to place than white) or :brown (alias :red; 6 dB
      # per octave, a deep rumble) filters the white noise
      # (Filter::NoiseColor; RMS about -14 dBFS, peaks past full scale
      # rare).
      #
      #     play noise(:pink).pan(drift(1)).at(-12.db)
      #     play noise(:brown).at(-6.db)
      def noise(color = :white, seed: nil)
        white = 2000.hz.ramp.noise(seed: seed)
        return white if color.nil? || color == :white

        white.filter(MB::Sound::Filter::NoiseColor.new(color, sample_rate: white.sample_rate))
      end

      # Sparse random impulses, about +rate+ per second (GraphNode::Dust):
      # Hz as a number, Pitch, or node (a swell of density), or the average
      # time between impulses (`1.beat`, `2.seconds`).  Heights are random
      # over +range+ (0..1, or -1..1 with +bipolar+), so as triggers they
      # strike at random velocities.  Seeded (+seed+, or drawn from
      # MB::Sound.seed's generator), the same at any buffer size.
      # +min_gap+ (seconds, a Length, or a Duration) keeps impulses at least
      # that far apart (the rate stays the average, up to one per gap).
      #
      # Examples:
      #     play dust(6).ping(3000, decay: 0.03).at(-6.db)              # drips
      #     play dust(300, bipolar: true).filter(:bandpass, cutoff: 2500, quality: 0.7).at(-12.db)  # crackle
      #     play dust(0.5, range: 0.4..1).resonate(:bowl, 196)          # a bowl struck now and then
      #     play dust(1.5, min_gap: 400.ms).resonate(:bowl, 196)         # never two strikes too close
      def dust(rate, bipolar: false, range: nil, min_gap: nil, seed: nil)
        MB::Sound::GraphNode::Dust.new(rate, bipolar: bipolar, range: range, min_gap: min_gap, seed: seed)
      end

      # A slow random line (GraphNode::Drift): +rate+ new random points per
      # second (Hz as a number, Pitch, or node, or the time between points:
      # `4.seconds`, `1.bar`) in +range+ (-1..1), joined by +smooth+ (:cubic
      # default, :cosine, :linear, or :step for a stepped sample-and-hold
      # line); +walk+ (0..1 of the range) makes each point stray at most
      # that far from the last.  +smooth+ may also be any tweening Curve
      # (`Curve[:back, overshoot: 0.3]`, `:elastic`, `:ease_in_out`;
      # overshooting curves leave +range+, unclamped).  +hold+ rests on each
      # point first: a share of the step (0..1), a time (`80.ms`, `1.n16`),
      # a Range of either for a random hold per point, or a node of shares.
      # +jitter+ (0..1 or a node) spaces the points unevenly (1 is
      # Poisson-like; the average rate stays).  +from+ starts the line at a
      # value instead of a random point.  Seeded (+seed+; points, holds, and
      # spacing each draw from their own stream), the same at any buffer
      # size.  For detune, cutoffs, pans, tape wow, and wandering drones.
      #
      # Examples:
      #     play 220.hz.transpose(drift(0.4, walk: 0.3).at(0.15)).saw.lp4(1500).at(-20.db)
      #     play noise.lp4(drift(0.3).at(200..2500), resonance: 0.3).at(-14.db)      # wind
      #     play 330.hz.triangle.pan(drift(3.seconds)).at(-18.db)
      #     # a restless creature darting around the stereo field: walk, random
      #     # holds, uneven spacing, an overshooting curve
      #     play noise(:pink).pan(drift(3, range: -0.75..0.75, walk: 0.5, hold: 30.ms..400.ms, jitter: 0.5, smooth: Curve[:elastic, overshoot: 0.5])).at(-10.db)
      def drift(rate = 0.2, range: -1.0..1.0, smooth: :cubic, walk: nil, hold: nil, jitter: nil, from: nil, seed: nil)
        MB::Sound::GraphNode::Drift.new(rate, range: range, smooth: smooth, walk: walk, hold: hold, jitter: jitter, from: from, seed: seed)
      end

      # Shortcut/DSL method for creating a tone with a given dynamic frequency
      # source, for full control over the FM signal graph.
      def tone(frequency)
        MB::Sound::Tone[frequency]
      end

      # Returns a source of zeros for +length+ (seconds or any length, e.g.
      # `480.samples` or `1.bar`), then the end of the stream (see
      # GraphNode::Silence), e.g. for appending a tail with
      # RoutingMethods#and_then.
      def silence(length, sample_rate: 48000)
        MB::Sound::GraphNode::Silence.new(length, sample_rate: sample_rate)
      end

      # Returns a node that generates a single sample impulse followed by
      # silence, for +length+ in all (5 seconds by default; any length).
      def impulse(length = 5)
        tapped = false
        silence(length).named('Single-sample impulse').spy { |d|
          unless tapped
            d[0] = 1
            tapped = true
          end
        }
      end

      # A scan wavetable from a list of frame sources (see Wavetable.of):
      # library table names, harmonic amplitudes, functions of phase,
      # tables, and sample arrays, one frame each, so a scan morphs through
      # them in order.  Prints itself back as this call (graph documents
      # save it; functions of phase need trust: :code to load unless they
      # use only arithmetic and Math on their phase).
      #
      #     t = wavetable_of(:sine, :saw, [1, 0.5, 0.33], ->(p) { Math.sin(2 * Math::PI * p) ** 3 }, normalize: :loudness)
      #     knob :shape, 0.0, range: 0.0..1.0
      #     bg 110.hz.wavetable(t, scan: knob(:shape)).at(-18.db)   # turn :shape to morph
      def wavetable_of(*sources, size: 2048, normalize: :peak, align: true, mips: :default, interpolation: nil, name: nil)
        MB::Sound::Wavetable.of(*sources, size: size, normalize: normalize, align: align, mips: mips, interpolation: interpolation, name: name)
      end
    end
  end
end
