module MB
  module Sound
    module Unison
      # Default per-copy glide times of Pitch#swarm (seconds, random per
      # copy) on Notes pitches.
      SWARM_GLIDE = (0.08..0.9).freeze

      # Default per-copy drift rates of Pitch#swarm (Hz, random per copy).
      SWARM_DRIFT_RATE = (0.05..0.35).freeze

      # Returns the detune offsets (semitones, lowest first) of +count+
      # swarm copies spread over the +chord+ tones (intervals or semitones
      # above the pitch): copy k takes tone k % chord.length, and the
      # copies on each tone are detuned around it by up to +detune+ with
      # +layout+ (see .offsets).
      #
      #     Unison.chord_offsets(6, [0, 7, 12], 10.cents, layout: :even)
      #     # => [-0.1, 0.1, 6.9, 7.1, 11.9, 12.1]
      def self.chord_offsets(count, chord, detune, layout: :random, rng: nil)
        count = Integer(count)
        raise ArgumentError, "A swarm needs at least one copy (got #{count})" if count < 1
        raise ArgumentError, 'A swarm chord needs at least one tone' if chord.empty?

        tones = chord.map { |t| Interval.semitones(t).to_f }
        groups = Array.new(tones.length, 0)
        count.times { |k| groups[k % tones.length] += 1 }

        tones.each_with_index.flat_map { |tone, j|
          next [] if groups[j] == 0
          offsets(groups[j], detune, layout: layout, rng: rng).map { |o| tone + o }
        }.sort
      end

      # Builds a swarm of +pitch+ (see Pitch#swarm for the arguments).
      def self.swarm(pitch, count, chord:, detune:, glide:, overshoot:, scatter:, from:, legato:, drift:, drift_rate:, shape: nil, cycles: nil, **unison, &block)
        notes_pitch = pitch.is_a?(Notes::NotePitch)
        glide = notes_pitch ? SWARM_GLIDE : nil if glide == :auto
        if !notes_pitch && (glide || scatter || from || (overshoot && overshoot != 0) || shape)
          raise ArgumentError, 'Swarm glides need a Notes pitch (v.hz, clip.tone, midi.hz); give glide: nil for a fixed pitch'
        end
        raise ArgumentError, 'A swarm scatter or start band needs a glide' if (scatter || from) && !glide
        raise ArgumentError, 'Give a swarm scatter: or from:, not both' if scatter && from

        band = from && start_band(from)

        scatter = scatter_range(scatter)
        drift = drift && (drift.respond_to?(:sample) ? drift : Interval.semitones(drift).to_f)

        detune = chord_offsets(count, chord, detune, layout: unison[:layout] || :random, rng: Random.new(swarm_seed(unison[:seed]))) if chord

        pitch.unison(count, detune: detune, **unison) do |p, i|
          if glide
            # A start band is absolute: the copy's own transpose (its chord
            # tone and detune) comes after the glide, so take it off
            start = band ? p.unison_copy.rand(band) - p.settings[:transpose] : scatter
            p = p.glide(glide, legato: legato, from: start, overshoot: overshoot, shape: shape, cycles: cycles)
          end
          if drift
            rate = p.unison_copy.pick(drift_rate)
            lfo = Tone.new(frequency: rate, sample_rate: p.sample_rate).lfo.rnd
            p = p.transpose(lfo * drift)
          end
          block ? block.call(p, i) : p.saw
        end
      end

      # Converts a swarm start band (a Range of Pitches, Notes, or note
      # numbers, or one of them) to a Range of note numbers in the current
      # tuning.
      def self.start_band(from)
        ends = from.is_a?(Range) ? [from.begin, from.end] : [from, from]
        a, b = ends.map { |v|
          case v
          when Pitch then MB::Sound.tuning.number_of(v.frequency)
          when Numeric then v.to_f
          else raise ArgumentError, "A swarm start band takes Pitches, Notes, or note numbers (got #{from.inspect})"
          end
        }
        a.to_f..b.to_f
      end

      # A seed for a chord layout: +seed+ itself, or a sub-seed of the root
      # generator.
      def self.swarm_seed(seed)
        seed.nil? ? MB::Sound.next_seed : Integer(seed) ^ 0x5eed
      end

      # Converts a swarm +scatter+ to a per-copy glide start: an Interval or
      # number of semitones becomes a Range either side of the first note,
      # and a Range (of Intervals or semitones) stays a Range of Intervals.
      def self.scatter_range(scatter)
        case scatter
        when nil then nil
        when Range
          a, b = Copy.endpoints(scatter)
          a.semitones..b.semitones
        when GraphNode::ChannelSpread, GraphNode::ChannelValues then scatter
        else
          s = Interval.semitones(scatter).to_f.abs
          (-s).semitones..s.semitones
        end
      end
    end
  end
end
