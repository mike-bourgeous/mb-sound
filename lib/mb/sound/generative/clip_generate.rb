module MB
  module Sound
    module Generative
      # A length in whole notes from a Duration, a Rational, or (for step
      # sizes, not cycle lengths) an Integer note division.
      def self.length_of(x, name, divisions: true)
        case x
        when Sequence::Duration then x.whole_notes
        when Rational then x
        when Integer
          unless divisions
            raise ArgumentError, "A generator's #{name} is a length like 2.bars or 1.n2 (a plain Integer is a note division elsewhere, so #{x} would be 1/#{x} of a whole note)"
          end
          Sequence::Duration.whole_notes(x)
        else raise ArgumentError, "#{name} is a length like 1.n8 or 2.bars (got #{x.inspect})"
        end.tap { |w| raise ArgumentError, "#{name} must be positive (got #{x.inspect})" unless w > 0 }
      end

      # Sequence::Clip.generate (extended into Clip's singleton class).
      module ClipGenerate
        # A generator clip: a loop of +length+ (a Duration like 2.bars, or
        # Rational whole notes) whose events in each cycle come from the
        # block, called with the cycle number (0 first) and the cycle's
        # Dice (Generative::Dice.new(seed, cycle); `dice[...]`/
        # `Dice.new(seed)` for draws shared between cycles).  The block
        # returns Events or rows [start, length, value, velocity, { marks }]
        # (whole notes from the cycle's start) and must depend only on the
        # cycle and the dice, so any cycle comes out the same computed cold
        # or after the others (seeks, takes, renders that start late).
        #
        # +values+ lists the notes the generator may play (drum kits build
        # voices for these; without it, the first cycle's notes).  +seed+
        # defaults to one drawn from MB::Sound's root seed.  +reach+ is how
        # late events may end (whole notes from their cycle's start; two
        # cycles by default).  The clip's own events (what it plays without
        # looping, and what listings show) are the first cycle's.
        #
        #     notes = scale(:minor, :a).notes(A3..A5)
        #     arp = Clip.generate(1.bar, values: notes) { |cycle, dice|
        #       Array.new(8) { |i| [i * 1r/8, 1r/16, dice.pick(notes, i), 0.7] }
        #     }
        #
        # +params+ (G3) are options the block reads as keywords, decided
        # once per cycle at its decision point, +lead+ (a length, one beat
        # by default) before the cycle: knobs, `cc`, tempo LFOs, choices,
        # or plain values (see Steer).
        #
        #     knob :busy, 0.3
        #     Clip.generate(1.bar, busy: knob(:busy)) { |cycle, dice, busy:|
        #       Array.new(16) { |i| [i * 1r/16, 1r/16, A3, 0.7] if dice.rand(:on, i) < busy }.compact
        #     }
        def generate(length, values: nil, seed: nil, name: nil, align: :timeline, reach: nil, loop: true, events: nil, lead: nil, params: {}, &block)
          length = Generative.length_of(length, :length, divisions: false)
          seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          reach = reach && Generative.length_of(reach, :reach, divisions: false)
          label = name&.to_s || "generate(seed: #{seed})"
          steer = Steer.build(params, length: length, what: label, lead: lead)
          if steer.nil? && !params.empty?
            # Nothing moves: the block gets the plain values every cycle
            fixed = params.transform_keys(&:to_sym).freeze
            inner = block
            block = ->(cycle, dice) { inner.call(cycle, dice, **fixed) }
          end
          gen = Generator.new(length, seed: seed, name: label, reach: reach, steer: steer, &block)
          values = values&.map { |v| v.is_a?(Integer) || !v.respond_to?(:to_midi) ? v : Scale.root_number(v) }
          Sequence::Clip.new(events || gen.preview(0), length: length, loop: loop, seed: seed, align: align,
            variations: [Sequence::Clip::Variation.new(name: gen.name, block: gen)], values: values)
        end
      end
    end

    Sequence::Clip.extend(Generative::ClipGenerate)
  end
end
