module MB
  module Sound
    module UI
      class Keyboard
        # Scale lock for the virtual keyboard (ux-r3 item 44): mash keys and
        # stay in a mode.  `ui.keyboard.scale = scale(:dorian, :d)`.
        #
        # Modes:
        # - :degrees (default) - white-key style: each white key of a row is
        #   the next degree of the scale, counting from the scale note at or
        #   above the row's C (z), so no key plays a wrong note; a black key
        #   plays the degree above the white key to its left.
        # - :snap - every key plays the scale note nearest its own pitch
        #   (ties go down), so the keyboard keeps its layout.
        #
        # Notes go out already mapped, so captures and step entry record the
        # notes heard.  CYCLE lists the scales the cycling keys step through.
        class ScaleLock
          # The modes (see the class comment).
          MODES = %i[degrees snap].freeze

          # Scales the cycle key steps through (nil: no lock).
          CYCLE = [nil, :major, :minor, :dorian, :mixolydian, :major_pentatonic, :minor_pentatonic, :blues].freeze

          # Semitone offsets of the white keys in an octave.
          WHITE = [0, 2, 4, 5, 7, 9, 11].freeze

          attr_reader :scale, :mode

          def initialize(scale, mode: :degrees)
            raise ArgumentError, "Scale lock modes are #{MODES.map(&:inspect).join(', ')} (got #{mode.inspect})" unless MODES.include?(mode)
            raise ArgumentError, "Scale lock needs a Scale (e.g. scale(:dorian, :d); got #{scale.inspect})" unless scale.is_a?(Scale)
            @scale = scale
            @mode = mode
          end

          # The MIDI note for the key +semis+ semitones above the row's
          # +base+ (its C).
          def note(base, semis)
            case @mode
            when :snap
              @scale.snap(base + semis).round
            when :degrees
              octave, within = semis.divmod(12)
              white = WHITE.rindex { |w| w <= within }
              black = !WHITE.include?(within)
              first = @scale.degree(@scale.snap(base, :up))[0]
              @scale.note(first + octave * 7 + white + (black ? 1 : 0)).round
            end
          end

          # A short label for the keyboard pane, e.g. "D dorian".
          def label
            root = Note.new(@scale.root).name.sub(/-?\d+\z/, '')
            "#{root} #{@scale.name || 'scale'}#{@mode == :snap ? ' (snap)' : ''}"
          end

          # The next lock in CYCLE after +lock+ (a ScaleLock or nil), keeping
          # its root and mode; nil after the last.
          def self.next_scale(lock, root: 0)
            i = CYCLE.index(lock&.scale&.name) || 0
            name = CYCLE[(i + 1) % CYCLE.length]
            name && new(Scale[name, lock ? lock.scale.root_class : root], mode: lock&.mode || :degrees)
          end

          # +lock+ with its root a fifth up (around the circle of fifths).
          def self.next_root(lock)
            return nil unless lock
            sc = lock.scale
            new(sc.with_root(sc.root - sc.root_class + (sc.root_class + 7) % 12), mode: lock.mode)
          end
        end
      end
    end
  end
end
