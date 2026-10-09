module MB
  module Sound
    module Sequence
      # A Clip built from steps played one after another, where steps may
      # leave their length unset.  The note length methods (#n8, #quarter,
      # #len, etc.) set the length of every unset step, so a whole sequence
      # can share a default:
      #
      #     seq(C4, E4, G4.n4).n8     # two eighth notes and a quarter note
      #
      # Steps that are still unset when the sequence plays or is combined with
      # other clips are quarter notes.
      #
      # Once a Seq is combined with other clips (e.g. with | or &), the result
      # is a plain Clip with every length resolved.
      class Seq < Clip
        # How far a slid note (Step#slide, `~C4`) sounds into the next step,
        # as a legato fraction of its last step: 1.02 overlaps the next note
        # by 2% of a step, so a mono voice glides (Notes::NotePitch#glide
        # with +legato: true+) and legato envelopes don't retrigger.
        SLIDE_LEGATO = 51/50r

        # One step of a Seq.  +value+ is nil for a rest.  +length+ is nil if
        # unset.  +legato+ is the fraction of the step the note sounds for (nil
        # for all of it).  +clip+ is set for a nested Clip that plays in place
        # of a single note.
        #
        # Note marks (see MB::Sound::Sequence::NoteMarks for Notes):
        # +accented+ is true for an accented note (#accent, `!C4`: velocity
        # Clip::ACCENT_VELOCITY, or Seq#acid's accent level); +slid+ is true
        # (or a legato fraction above 1) for a note that slides into the
        # next (#slide, `~C4`: it sounds SLIDE_LEGATO of its last step, so
        # it overlaps the next note); +tie+ is true for a step that holds the
        # previous note one more step (MB::Sound::Tie).  Marks return new
        # Steps and chain in any order: `~!A1`, `!A1.up`, `A1.!.~`,
        # `A1.acc.s!.n8`.
        Step = Struct.new(:value, :length, :velocity, :probability, :legato, :clip, :accented, :slid, :tie, keyword_init: true) do
          include NoteMethods

          # True for a rest (no note, clip, or tie).
          def rest?
            value.nil? && clip.nil? && tie != true
          end

          # True for a tie step (MB::Sound::Tie).
          def tie?
            tie == true
          end

          # True for an accented step (#accent).
          def accented?
            accented == true
          end

          # True for a step that slides into the next (#slide).
          def slid?
            !slid.nil? && slid != false
          end

          # Returns a copy of this step with an accent: the accent flag and
          # Clip::ACCENT_VELOCITY (Seq#acid uses its own accent level).
          # Aliases #acc, #a!, and unary ! (`!A1`).
          def accent
            marked(accented: true, velocity: value.nil? ? velocity : Clip::ACCENT_VELOCITY)
          end
          alias acc accent
          alias a! accent
          alias ! accent

          # Returns a copy of this step that slides into the next note: it
          # sounds +overlap+ of its last step (default SLIDE_LEGATO, 1.02),
          # overlapping the next note-on so a mono voice glides and legato
          # envelopes don't retrigger.  Aliases #s! and unary ~ (`~A1`).
          def slide(overlap = true)
            overlap = Clip.check_legato(overlap) unless overlap == true
            marked(slid: overlap)
          end
          alias s! slide
          alias ~ slide

          # Returns a copy of this step +octaves+ (default 1) higher.
          def up(octaves = 1)
            oct(octaves)
          end

          # Returns a copy of this step +octaves+ (default 1) lower.
          def dn(octaves = 1)
            oct(-octaves)
          end
          alias down dn

          # Returns a copy of this step moved by +octaves+ (negative for
          # lower).
          def oct(octaves)
            semitones = 12 * octaves
            marked(value: value && Sequence.transpose_value(value, semitones), clip: clip&.transpose(semitones))
          end

          # Returns a one-step Seq of this step (see NoteMethods for #n8,
          # #quarter, ...).
          def to_seq
            Seq.new([self])
          end

          private

          # A copy with +changes+ (Steps may be frozen, like MB::Sound::Rest).
          def marked(**changes)
            Step.new(**to_h.merge(changes))
          end
        end

        # Converts an item given to MB::Sound#seq into a Step: a Note or
        # Numeric is a note or value, nil or :rest is a rest, and a Clip plays
        # in place.
        def self.step(item)
          case item
          when Step
            item

          when Clip
            Step.new(clip: item, length: item.length)

          when MB::Sound::Note
            # detuned_number keeps cents (e.g. 'A4+20'); whole notes stay Integers
            Step.new(value: item.detune == 0 ? item.number : item.detuned_number, velocity: DEFAULT_VELOCITY)

          when MB::Sound::Pitch
            # A fixed frequency (e.g. 440.hz), kept as a Pitch (see Notes::Node#number_of)
            Step.new(value: item, velocity: DEFAULT_VELOCITY)

          when Numeric
            Step.new(value: item, velocity: DEFAULT_VELOCITY)

          when nil, :rest
            Step.new

          when false
            raise ArgumentError, 'Cannot sequence false; `!A1.n8` is `!(A1.n8)`: write `(!A1).n8`, `A1.acc.n8`, or `A1.n8.acc`'

          else
            raise ArgumentError, "Cannot sequence #{item.inspect}; use Notes (e.g. C4), numbers, nil for a rest, or other clips"
          end
        end

        # The Event for a note +step+ starting at +start+, held for +total+
        # whole notes (its step plus any ties), the last step being +last+
        # long: it sounds until +last+ × the step's legato before the end, or
        # into the next step for a +slide+ (true for SLIDE_LEGATO, or a
        # legato fraction).
        def self.note_event(step, start, total, last, slide)
          legato = slide ? (slide == true ? SLIDE_LEGATO : slide) : (step.legato || 1)
          Event.new(
            start: start, length: total - last + last * legato, value: step.value, velocity: step.velocity,
            probability: step.probability, accented: step.accented || nil, slid: slide ? true : nil
          )
        end

        # The Steps in this sequence.
        attr_reader :steps

        # Creates a sequence from a list of items (see Seq.step).  Nested Seqs
        # are flattened so that their unset steps can still be given a length
        # (e.g. `seq(C4, rest, E4).n8`).
        def initialize(items, seed: 0, loop: false, align: :timeline)
          @steps = items.flat_map { |i| i.is_a?(Seq) ? i.steps : [Seq.step(i)] }.freeze

          t = 0r
          events = []
          held = nil # the note being built: [step, start, total length, last step's length, slide]
          @steps.each do |s|
            len = s.length || Duration::DEFAULT
            if s.tie?
              # A tie holds the previous note one more step (a rest after a
              # rest, a clip, or at the start)
              if held
                held[2] += len
                held[3] = len
                held[4] ||= s.slid
              end
            else
              events << Seq.note_event(*held) if held
              held = nil
              if s.clip
                events.concat(s.clip.events.map { |e| e.with(start: e.start + t) })
              elsif !s.rest?
                held = [s, t, len, len, s.slid]
              end
            end
            t += len
          end
          events << Seq.note_event(*held) if held

          super(events, length: t, seed: seed, loop: loop, align: align)
        end

        # Returns a looping copy of this Seq (see Clip#loop), still a Seq, so
        # step transforms (#acid, #accent, #len, #permute, ...) keep working
        # on loops: `line.loop.acc`.
        def loop(seed: @seed, align: @align)
          Seq.new(@steps, seed: seed, loop: true, align: align)
        end

        Duration::DIVISIONS.each do |k|
          define_method("n#{k}") { n(k) }
        end

        # Sets the length of every unset step to 1/+k+ of a whole note.  Most
        # common divisions have their own methods, e.g. #n4 or #n16.
        def n(k)
          len(Rational(1, Integer(k)))
        end

        Duration::NAMES.each do |name, k|
          define_method(name) { n(k) }
        end

        # Sets the length of every unset step to +duration+ (an Integer note
        # division or Rational whole notes).
        def len(duration)
          whole = Duration.whole_notes(duration)
          map_steps { |s| s.length ? s : s.to_h.merge(length: whole) }
        end

        # Sets the length of every unset step to +count+ quarter-note beats.
        def beats(count)
          len(count.to_r / 4)
        end

        # Returns a Seq that plays this sequence's steps +count+ times.  Unlike
        # Clip#repeat, the result is still a Seq, so unset lengths can be set
        # afterward:
        #
        #     seq(C4, E4).repeat(4).n8    # eight eighth notes
        def repeat(count)
          raise ArgumentError, "Repeat count must be a positive Integer (got #{count.inspect})" unless count.is_a?(Integer) && count > 0
          warn "repeat makes a finite clip, so #{self} will stop looping; call .loop on the result to keep looping" if @loop
          Seq.new(@steps * count, seed: @seed)
        end
        alias * repeat

        # Returns a Seq with every step's length (resolving unset steps to
        # quarter notes) multiplied by +factor+.
        def stretch(factor)
          factor = factor.to_r
          raise ArgumentError, 'Stretch factor must be positive' unless factor > 0
          map_steps { |s|
            len = (s.length || Duration::DEFAULT) * factor
            s.to_h.merge(length: len, clip: s.clip&.stretch(factor))
          }
        end

        # Returns a Seq where every note sounds for +fraction+ of its step (see
        # Clip#legato), keeping unset lengths settable.  Slid notes keep
        # their overlap.
        def legato(fraction)
          fraction = Clip.check_legato(fraction)
          map_steps { |s| s.to_h.merge(legato: fraction, clip: s.clip&.legato(fraction)) }
        end

        # Returns a Seq with every note's value shifted by +semitones+.
        def transpose(semitones)
          map_steps { |s|
            s.to_h.merge(value: s.value && Sequence.transpose_value(s.value, semitones), clip: s.clip&.transpose(semitones))
          }
        end

        # Returns a Seq with the steps in reverse order (nested clips are
        # reversed too; see Clip#reverse), keeping unset lengths settable.
        # Ties (MB::Sound::Tie) stay after the note they hold.
        #
        #     seq(C4, E4, G4).reverse.n8    # G4, E4, C4
        def reverse
          # Ties stay after the step they hold
          units = []
          @steps.each do |s|
            if s.tie? && !units.empty?
              units.last << s
            else
              units << [s.clip ? Step.new(**s.to_h.merge(clip: s.clip.reverse)) : s]
            end
          end
          Seq.new(units.reverse.flatten(1), seed: @seed, loop: @loop, align: @align)
        end
        alias retrograde reverse

        # Returns a Seq with its notes (values, velocities, probabilities,
        # accents, and slides) moved among the note steps, keeping each
        # step's length, so unset lengths stay settable.  Rests, ties, and
        # nested clips stay where they are (a tie holds whichever note lands
        # before it).
        # See Clip#permute for +order+ and +:seed+; +order+ indexes the note
        # steps only.
        def permute(order = nil, seed: @seed)
          notes = @steps.each_index.select { |i| @steps[i].value }
          order = Clip.check_permutation(order, notes.length, seed)

          steps = @steps.dup
          notes.each_with_index do |slot, idx|
            src = @steps[notes[order[idx]]]
            steps[slot] = Step.new(**@steps[slot].to_h.merge(value: src.value, velocity: src.velocity, probability: src.probability, accented: src.accented, slid: src.slid))
          end

          Seq.new(steps, seed: @seed, loop: @loop, align: @align)
        end
        alias shuffle permute

        # Returns a Seq with every note's velocity set to +velocity+ (0..1).
        def vel(velocity)
          map_steps { |s|
            s.to_h.merge(velocity: s.value && velocity.to_f, clip: s.clip&.vel(velocity))
          }
        end

        # Returns a Seq with every note accented (see Step#accent).  Aliases
        # #acc and #a!; unary ! works on Notes and Steps only, so write
        # `(!A1).n8` or `A1.n8.acc`, since `!A1.n8` is `!(A1.n8)`.
        def accent
          map_notes(&:accent)
        end
        alias acc accent
        alias a! accent

        # Returns a Seq with every note sliding into the next (see
        # Step#slide).  Alias #s!.
        def slide(overlap = true)
          map_notes { |s| s.slide(overlap) }
        end
        alias s! slide

        # Returns a Seq +octaves+ (default 1) higher.
        def up(octaves = 1)
          transpose(12 * octaves)
        end

        # Returns a Seq +octaves+ (default 1) lower.
        def dn(octaves = 1)
          transpose(-12 * octaves)
        end
        alias down dn

        # Returns a Seq moved by +octaves+.
        def oct(octaves)
          transpose(12 * octaves)
        end

        # Returns a Seq played like a TB-303's sequencer: notes sound for
        # +gate+ of their last step (the 303's gate falls about halfway
        # through a step; ties hold until then), slid notes (Step#slide,
        # `~A1`) for +slide+ of it instead (overlapping the next note, so a
        # mono voice glides and its envelopes don't retrigger), and
        # velocities are +accent+ for accented notes (Step#accent, `!A1`)
        # and +normal+ for the rest (see Notes#accent for a 0/1 accent
        # signal).  Nested Seqs are converted too.  MB::Sound#acid is
        # `seq(...).acid` with 16th-note steps.
        #
        #     line = seq(A1, !A1, ~A2, A1, Rest, C2, !A1, Tie).n16.acid.loop
        def acid(accent: 1.0, normal: 0.6, gate: 0.5, slide: SLIDE_LEGATO)
          accent = Float(accent)
          normal = Float(normal)
          raise ArgumentError, "Acid velocities must be 0..1 (got #{accent}, #{normal})" unless (0.0..1.0).cover?(accent) && (0.0..1.0).cover?(normal)
          gate = Clip.check_legato(gate)
          slide = Clip.check_legato(slide)

          map_steps { |s|
            if s.clip
              s.clip.is_a?(Seq) ? s.to_h.merge(clip: s.clip.acid(accent: accent, normal: normal, gate: gate, slide: slide)) : s
            elsif s.value.nil?
              s
            else
              s.to_h.merge(velocity: s.accented? ? accent : normal, legato: gate, slid: s.slid? ? slide : nil)
            end
          }
        end

        private

        # A Seq with every note step (and the notes of nested Seqs) changed
        # by the block, which gets and returns a Step.
        def map_notes(&block)
          map_steps { |s|
            if s.clip
              s.clip.is_a?(Seq) ? s.to_h.merge(clip: s.clip.send(:map_notes, &block)) : s
            elsif s.value.nil?
              s
            else
              yield s
            end
          }
        end

        # Builds a new Seq with the same seed from steps changed by the block,
        # which may return a Step or a Hash of Step attributes.
        def map_steps
          Seq.new(@steps.map { |s| r = yield s; r.is_a?(Hash) ? Step.new(**r) : r }, seed: @seed, loop: @loop, align: @align)
        end

        # Seq's own versions of Clip transforms also remember their source.
        track_derivations(
          :loop, :repeat, :*, :stretch, :legato, :transpose, :vel, :reverse, :retrograde, :permute, :shuffle,
          :accent, :acc, :a!, :slide, :s!, :up, :dn, :down, :oct, :acid
        )
      end
    end
  end
end
