module MB
  module Sound
    module Generative
      # A named chord as a value: a quality (:min7, :maj, :sus4, ...) on a
      # root, made by MB::Sound#chord with a quality Symbol and +root:+
      # (`chord(:min7, root: :d)`; without +root:+, `chord` is still the
      # MIDI transform).  #weights is a chord layer for probability scales,
      # like `tones(...)`:
      #
      #     key.blur(0.15) + chord(:min7, root: :d).weights * 1.5
      #     chord(:min7, root: :d).weights(2, 1, 1.5, 1)   # root, third, fifth, seventh
      #     chord(:maj7, root: F3).notes                   # => [F3, A3, C4, E4]
      #     chord(:min, root: :a3, inversion: 1).notes     # => [C4, E4, A4]
      #     harmony(0 => chord(:min7, root: :d), 2.bars => chord(:dom7, root: :g), loop: 4.bars, curve: :step)
      #
      # Roots are note names (`:d`, `:fs`, `:bb3`; octave 4 without a
      # number, as in `scale`), Notes (D3), note numbers, or Pitches
      # (rounded to the nearest note).  Qualities are QUALITIES' names and
      # their aliases (the same shapes as the MIDI transform, e.g.
      # `midi.chord(:min7)`).  +inversion:+ moves that many of the lowest
      # notes up an octave (#notes only; the weights are pitch classes).
      class Chord
        include Value

        # Other names for MIDI::Transform::Chord::SHAPES besides its own
        # ALIASES (m7b5, 6, m6, M7, 7, 9, ...).
        EXTRA_ALIASES = { m7b5: :min7b5, '6': :maj6, m6: :min6, M7: :maj7, dim5: :dim, dom: :dom7 }.freeze

        # The chord shapes by name, in semitones above the root (root first).
        def self.qualities
          MIDI::Transform::Chord::SHAPES
        end

        # The shape name for +quality+ (a Symbol or String, aliases
        # resolved), or nil if it isn't a chord name.
        def self.shape_name(quality)
          return nil unless quality.is_a?(Symbol) || quality.is_a?(String)
          name = quality.to_sym
          name = MIDI::Transform::Chord::ALIASES.fetch(name) { EXTRA_ALIASES.fetch(name, name) }
          qualities.key?(name) ? name : nil
        end

        # True when MB::Sound#chord's arguments ask for a chord value: one
        # quality Symbol or String and +root:+ (the MIDI transform takes
        # +root:+ only with scale steps, never with a chord name).
        def self.value_call?(args, kwargs)
          args.length == 1 && (args[0].is_a?(Symbol) || args[0].is_a?(String)) && kwargs.key?(:root) && !kwargs.key?(:scale)
        end

        # The note number of a chord root (see the class description).
        def self.root_number(root)
          n = case root
              when Note then root.number
              when Pitch then MB::Sound.tuning.number_of(root.frequency).round
              when Integer then root
              when Symbol, String then Scale.root_number(root)
              else raise ArgumentError, "A chord root is a note name (:d, :fs3), a Note, a note number, or a Pitch (got #{root.inspect})"
              end
          raise ArgumentError, "Chord roots are whole notes (got #{root.inspect})" unless n == n.round
          n.round
        end

        # The quality's shape name (a key of QUALITIES).
        attr_reader :quality

        # The root's note number.
        attr_reader :root

        # How many of the lowest notes #notes moves up an octave.
        attr_reader :inversion

        def initialize(quality, root:, inversion: 0)
          @quality = Chord.shape_name(quality)
          raise ArgumentError, "Unknown chord quality #{quality.inspect} (#{Chord.qualities.keys.join(', ')}; aliases #{MIDI::Transform::Chord::ALIASES.merge(EXTRA_ALIASES).keys.join(', ')})" unless @quality
          @root = Chord.root_number(root)
          @offsets = Chord.qualities[@quality]
          unless inversion.is_a?(Integer) && inversion.between?(0, @offsets.length - 1)
            raise ArgumentError, "A #{@quality} chord's inversion is an Integer from 0 to #{@offsets.length - 1} (got #{inversion.inspect})"
          end
          @inversion = inversion
        end

        # Freezes after the recipe is set (see Value#with_recipe).
        def with_recipe(*)
          super
          freeze
        end

        # The chord's Notes from the lowest up (after the inversion).
        def notes
          numbers = @offsets.map { |o| @root + o }
          numbers = numbers.drop(@inversion) + numbers.first(@inversion).map { |n| n + 12 }
          numbers.map { |n| Note.new(n) }
        end
        alias to_a notes

        # The chord as a probability scale layer (Weights): each chord tone's
        # pitch class at 1, or at +per_tone+ (one weight per chord tone from
        # the root up, before any inversion, cycled), others 0.  With no
        # weights, the same as `tones(*chord.notes)`.
        def weights(*per_tone)
          per_tone = per_tone.flatten
          per_tone.each { |w|
            raise ArgumentError, "Chord weights are finite numbers, not negative (got #{w.inspect})" unless w.is_a?(Numeric) && w.real? && w.finite? && w >= 0
          }
          pc = Array.new(12, 0.0)
          @offsets.each_with_index do |o, i|
            w = per_tone.empty? ? 1.0 : per_tone[i % per_tone.length].to_f
            c = (@root + o) % 12
            pc[c] = w if w > pc[c]
          end
          Weights.new(pc).with_recipe(self, :weights, per_tone)
        end

        def ==(other)
          other.is_a?(Chord) && other.quality == @quality && other.root == @root && other.inversion == @inversion
        end
        alias eql? ==

        def hash
          [@quality, @root, @inversion].hash
        end

        def to_s
          "#{Note.new(@root).name}#{@quality}#{" (inversion #{@inversion})" if @inversion != 0}"
        end

        def inspect
          "#<Chord #{self}: #{notes.map(&:name).join(' ')}>"
        end

        # `chord(:quality, root: N)` (chords always have a recipe from
        # MB::Sound#chord; this is for ones made with Chord.new).
        def plain_ruby(value_text)
          "chord(#{value_text.call(@quality)}, root: #{value_text.call(Note.new(@root))}#{", inversion: #{@inversion}" if @inversion != 0})"
        end
      end
    end
  end
end
