module MB
  module Sound
    # The generative layer (design/notes/generative.md): counter-based Dice,
    # probability scales (Weights, Field, Harmony), and generator clips
    # (Sequence::Clip.generate, MB::Sound#strikes, MB::Sound#melody) whose
    # events for each cycle are pure functions of the seed and the cycle,
    # so they seek, replay in takes, and render the same at any buffer size.
    # Console methods are in GenerativeMethods.
    module Generative
      # Weights from +x+: Weights, a Scale (its notes at 1), a Chord (its
      # tones at 1), or an Array of notes (a chord layer).
      def self.weights(x)
        case x
        when Weights then x
        when Scale, Chord then x.weights
        when Array then Weights.tones(*x)
        else raise ArgumentError, "Expected Weights, a Scale, a Chord, or an Array of notes (got #{x.inspect})"
        end
      end

      # The Field of +source+ at clip +position+ (whole notes): Fields and
      # FieldTimelines answer #at; Weights, Harmonies, and Scales spread
      # over +range+ (C3..C5 by default).
      def self.field_at(source, position, range: DEFAULT_RANGE)
        case source
        when Field then source
        when FieldTimeline then source.at(position)
        else field(source, range: range).at(position)
        end
      end

      # The range a Weights or Harmony spreads over when no Field gives one.
      DEFAULT_RANGE = (48..72).freeze

      # A Field or FieldTimeline from +source+ (Weights, Harmony, Scale,
      # Field, FieldTimeline), spreading Weights over +range+.
      def self.field(source, range: DEFAULT_RANGE)
        case source
        when Field, FieldTimeline then source
        when Harmony then source.over(range)
        else weights(source).over(range)
        end
      end

      # The Field or FieldTimeline MB::Sound#motifs draws from: Fields as
      # they are (their own range), Harmonies and Weights over +range+
      # (C3..C5 by default) with an optional bell; a Scale's root weighs
      # 1.5 (so answers have a home to land on).
      def self.motif_field(source, range: nil, around: nil, width: nil)
        case source
        when Field, FieldTimeline
          raise ArgumentError, 'A Field has its own range; leave out range: and width: (or pass the Weights or Harmony)' if range || width
          source
        when Harmony then source.over(range || DEFAULT_RANGE, around: around, width: width)
        when Scale then (source.weights + Weights.tones(source.root) * 0.5).over(range || DEFAULT_RANGE, around: around, width: width)
        else weights(source).over(range || DEFAULT_RANGE, around: around, width: width)
        end
      end

      # The note numbers +source+ (a Field or FieldTimeline) may play.
      def self.notes_of(source)
        case source
        when Field then source.notes.select.with_index { |_, i| source.weights[i] > 0 }
        when FieldTimeline then source.notes
        end
      end
    end
  end
end

require_relative 'generative/dice'
require_relative 'generative/value'
require_relative 'generative/weights'
require_relative 'generative/chord'
require_relative 'generative/field'
require_relative 'generative/harmony'
require_relative 'generative/producer'
require_relative 'generative/ahead'
require_relative 'generative/generator'
require_relative 'generative/strikes'
require_relative 'generative/melody'
require_relative 'generative/scale_weights'
require_relative 'generative/clip_generate'
require_relative 'generative/motifs'
