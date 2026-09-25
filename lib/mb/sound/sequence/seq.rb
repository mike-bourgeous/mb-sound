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
        # One step of a Seq.  +value+ is nil for a rest.  +length+ is nil if
        # unset.  +legato+ is the fraction of the step the note sounds for (nil
        # for all of it).  +clip+ is set for a nested Clip that plays in place
        # of a single note.
        Step = Struct.new(:value, :length, :velocity, :probability, :legato, :clip, keyword_init: true) do
          def rest?
            value.nil? && clip.nil?
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
            Step.new(value: item.number, velocity: DEFAULT_VELOCITY)

          when Numeric
            Step.new(value: item, velocity: DEFAULT_VELOCITY)

          when nil, :rest
            Step.new

          else
            raise ArgumentError, "Cannot sequence #{item.inspect}; use Notes (e.g. C4), numbers, nil for a rest, or other clips"
          end
        end

        # The Steps in this sequence.
        attr_reader :steps

        # Creates a sequence from a list of items (see Seq.step).  Nested Seqs
        # are flattened so that their unset steps can still be given a length
        # (e.g. `seq(C4, rest, E4).n8`).
        def initialize(items, seed: 0)
          @steps = items.flat_map { |i| i.is_a?(Seq) ? i.steps : [Seq.step(i)] }.freeze

          t = 0r
          events = []
          @steps.each do |s|
            len = s.length || Duration::DEFAULT
            if s.clip
              events.concat(s.clip.events.map { |e| e.with(start: e.start + t) })
            elsif !s.rest?
              events << Event.new(start: t, length: len * (s.legato || 1), value: s.value, velocity: s.velocity, probability: s.probability)
            end
            t += len
          end

          super(events, length: t, seed: seed)
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
        # Clip#legato), keeping unset lengths settable.
        def legato(fraction)
          fraction = Clip.check_legato(fraction)
          map_steps { |s| s.to_h.merge(legato: fraction, clip: s.clip&.legato(fraction)) }
        end

        # Returns a Seq with every note's value shifted by +semitones+.
        def transpose(semitones)
          map_steps { |s|
            s.to_h.merge(value: s.value && s.value + semitones, clip: s.clip&.transpose(semitones))
          }
        end

        # Returns a Seq with every note's velocity set to +velocity+ (0..1).
        def vel(velocity)
          map_steps { |s|
            s.to_h.merge(velocity: s.value && velocity.to_f, clip: s.clip&.vel(velocity))
          }
        end

        private

        # Builds a new Seq with the same seed from steps changed by the block,
        # which may return a Step or a Hash of Step attributes.
        def map_steps
          Seq.new(@steps.map { |s| r = yield s; r.is_a?(Hash) ? Step.new(**r) : r }, seed: @seed)
        end
      end
    end
  end
end
