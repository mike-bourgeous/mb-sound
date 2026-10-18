module MB
  module Sound
    module UI
      class Keyboard
        # Scale lock for the virtual keyboard (ux-r3 item 44; rebuilt on the
        # MIDI layer's lock styles in midi-consol-2): mash keys and stay in
        # a mode.  `ui.keyboard.scale = scale(:dorian, :d)`.
        #
        # Each mode is a MIDI::Lock::Style, the same note map that
        # `stream.lock(...)` and the console's `lock` apply to external
        # keyboards, so a computer key and the same key on a MIDI keyboard
        # give the same note:
        # - :mash (default, maintainer 2026-10-18: every key in scale, never
        #   a wrong note) - each white key the next degree, flowing from the
        #   root on middle C; black keys silent.
        # - :play (also :degrees) - degrees fitted to the octave (the
        #   scale's root on every C), black keys passing notes between their
        #   neighbours (silent between half steps).
        # - :along (also :snap) - every key plays the scale note nearest its
        #   own pitch (ties go down), keeping the layout.
        #
        # Notes go out already mapped, so captures and step entry record the
        # notes heard.  CYCLE lists the scales the cycling keys step through.
        class ScaleLock
          # The modes (see the class comment), and the older names.
          MODES = %i[mash play along].freeze
          ALIASES = { degrees: :play, snap: :along }.freeze

          # Scales the cycle key steps through (nil: no lock).
          CYCLE = [nil, :major, :minor, :dorian, :mixolydian, :major_pentatonic, :minor_pentatonic, :blues].freeze

          attr_reader :scale, :mode, :style

          def initialize(scale, mode: :mash)
            m = ALIASES.fetch(mode, mode)
            raise ArgumentError, "Scale lock modes are #{(MODES + ALIASES.keys).map(&:inspect).join(', ')} (got #{mode.inspect})" unless MODES.include?(m)
            raise ArgumentError, "Scale lock needs a Scale (e.g. scale(:dorian, :d); got #{scale.inspect})" unless scale.is_a?(Scale)
            @scale = scale
            @mode = m
            @style = MIDI::Lock::Style.new(m, scale: scale)
          end

          # The MIDI note for the key +semis+ semitones above the row's
          # +base+ (its C), or nil for a silent key: the key's note number
          # through the lock style (see the class comment).
          def note(base, semis)
            n = @style.map_note(base + semis, nil, transport: nil)
            n && MIDI::Transform::Transpose.whole(n)
          end

          # A short label for the keyboard pane, e.g. "D dorian".
          def label
            root = Note.new(@scale.root).name.sub(/-?\d+\z/, '')
            "#{root} #{@scale.name || 'scale'}#{@mode == :mash ? '' : " (#{@mode})"}"
          end

          # The next lock in CYCLE after +lock+ (a ScaleLock or nil), keeping
          # its root and mode; nil after the last.
          def self.next_scale(lock, root: 0)
            i = CYCLE.index(lock&.scale&.name) || 0
            name = CYCLE[(i + 1) % CYCLE.length]
            name && new(Scale[name, lock ? lock.scale.root_class : root], mode: lock&.mode || :mash)
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
