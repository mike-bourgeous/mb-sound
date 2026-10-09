module MB
  module Sound
    module Sequence
      # Note marks added to MB::Sound::Note: each returns a Seq::Step (which
      # MB::Sound#seq takes as a step) with the mark, and Steps have the same
      # marks, so they chain in any order: `~!A1`, `!A1.up`, `A1.!.~`,
      # `A1.acc.s!.n8`.
      #
      # - Accent: #accent, #acc, #a!, or unary ! (`!A1`): velocity
      #   Clip::ACCENT_VELOCITY (1.0, against the default 0.75), or the
      #   accent level of Seq#acid.
      # - Slide: #slide, #s!, or unary ~ (`~A1`; `~!A1` for both, since Ruby
      #   reads `!~` as its not-match operator): the note overlaps the next
      #   (Seq::SLIDE_LEGATO), so a mono voice glides and legato envelopes
      #   don't retrigger.
      #
      # Octave marks (Pitch#up, #dn, #oct) return Notes, and work on Steps
      # too.  Method calls bind before unary operators: `!A1.n8` is
      # `!(A1.n8)`, so write `(!A1).n8` or `A1.acc.n8`.  -A1 and +A1 are not
      # marks (minus is reserved for inverting signals).
      #
      # Only Notes and Steps override !, so code that might hold one tests
      # it with #nil? rather than ! (see spec/lib/mb/sound/note_negation_spec.rb).
      module NoteMarks
        # This note as a Seq::Step (see Seq.step).
        def to_step
          Seq.step(self)
        end

        # An accented Seq::Step of this note (see Seq::Step#accent).
        # Aliases #acc, #a!, and unary ! (`!A1`).
        def accent
          to_step.accent
        end
        alias acc accent
        alias a! accent
        alias ! accent

        # A Seq::Step of this note sliding into the next (see
        # Seq::Step#slide).  Aliases #s! and unary ~ (`~A1`).
        def slide(overlap = true)
          to_step.slide(overlap)
        end
        alias s! slide
        alias ~ slide

        # A Seq::Step of this note playing with probability +p+ per loop
        # cycle (see Seq::Step#chance).  Alias #maybe.
        def chance(p)
          to_step.chance(p)
        end
        alias maybe chance

        # A Seq::Step of this note playing every +n+th loop cycle from cycle
        # +from+ (see Seq::Step#every).
        def every(n, from: 1)
          to_step.every(n, from: from)
        end
      end
    end
  end
end
