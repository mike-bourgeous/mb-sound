module MB
  module Sound
    module Generative
      # How a morph cuts a generator's events into slots (see Morph): +by+
      # :note (drum beats: a slot is one drum's step, and the nth hit of
      # that drum there) or :beat (melodic lines, strikes, chords: a slot is
      # one beat of the line, all its notes together); +grid+ the step
      # length in whole notes (a drum step, or a beat); +hold+ how many
      # cycles a beat holds its draws (Beats' hold), so a held bar morphs
      # the same way twice; +anchors+ the drum steps that never drift
      # ({ [note, start] => true }, Beats' keep: steps; nil for none), which
      # switch at the middle of the sweep.
      Slots = Data.define(:by, :grid, :hold, :anchors) do
        # Slots for a beats generator's +rows+ (Beats::Row) of +step+ whole
        # notes, holding its draws for +hold+ cycles: by drum and step when
        # every row plays a drum note, else by beat (a melodic rhythm line).
        def self.of_beats(rows, step, hold)
          return Slots.new(by: :beat, grid: 1r / 4, hold: hold, anchors: nil) unless rows.all?(&:note)
          anchors = rows.flat_map { |r| r.keep.map { |s| [r.note, step * s] } }.to_h { |k| [k.freeze, true] }.freeze
          Slots.new(by: :note, grid: step, hold: hold, anchors: anchors.empty? ? nil : anchors)
        end
      end

      # Slots by beat (the default for generators).
      Slots::BEAT = Slots.new(by: :beat, grid: 1r / 4, hold: 1, anchors: nil)

      # A generator morphing between two others, A and B (gen-morph-1,
      # 2026-11-22, built to the design of the drum generators' morph
      # study; MB::Sound::Library::Generators.morph makes them from
      # `L.gen.beat.dnb.morph(L.gen.beat.house)`): its events, cycle by
      # cycle, are A's and B's crossfaded slot by slot by +morph+ (0..1, a
      # number or a param, read like any steered value).
      #
      # The one rule: every slot (Slots: a drum's step for beats, one beat
      # for melodic lines) has a threshold tau in (0, 1], drawn from both
      # sides' seeds and the slot (counter-based, so a cycle is a pure
      # function of the seeds and the decided values).  While morph < tau
      # the slot plays A's notes there; from tau on, B's.  So at 0 every
      # slot is A's and the morph plays exactly A, at 1 exactly B, and each
      # slot changes once over a sweep; a note both sides play at a slot is
      # in both versions, so it stays.  Anchors (Beats' keep: steps, of
      # either side) switch at 0.5; at exactly 0.5 a slot only one side
      # anchors keeps that side's hit, so the skeleton never empties.
      #
      # Each side keeps its own seed, params, and decisions: the morph's
      # Steer reads +morph+ and every moving param of both sides (as
      # "a.energy", "b.energy") for each unit (the shorter of the sides'
      # units: a beat for beats, the cycle for melodic lines; the longer
      # lead), and computes each side's cycle with its values
      # (Generator#events_with).  Each side's events keep their own order
      # (equal starts don't reshuffle), and a ghost row and the snare
      # hitting one note on one step are two slots (the nth hit there).
      #
      # The morph's cycle is the longer side's when one cycle length
      # divides the other (a 2-bar line with a 1-bar one: the short side's
      # cycles in turn); other lengths raise.
      class Morph < Generator
        # One side of a morph: the +clip+, its +producer+ (the clip's
        # generator variation, or nil for a fixed loop), +keys+ (its
        # Steer's param names), +params+ (name => param), +unit+ and +lead+
        # (whole notes), its Slots, its +seed+.
        Side = Data.define(:clip, :producer, :keys, :params, :unit, :lead, :slots, :seed, :label) do
          # The cycle length in whole notes.
          def length = clip.length

          # The events of +cycle+ as the side's clip plays them (its
          # variations applied in order), computed with +values+ (the
          # side's decided values, or nil).
          def events(cycle, values)
            clip.variations.reduce(clip.events) { |evs, v|
              v.block.is_a?(Producer) ? v.block.events_with(cycle, values) : v.block.call(evs, cycle, clip)
            }
          end
        end

        # Raised for pairs that can't morph (with how to play them instead).
        class Refused < ArgumentError; end

        class << self
          # The Side for +clip+ (a looping Clip: a generator's, or a fixed
          # loop), labeled +label+ in errors; raises Refused for clips
          # that can't be a side.
          def side(clip, label)
            raise Refused, "#{label} is not a clip: a morph blends two generators (L.gen)" unless clip.is_a?(Sequence::Clip)
            raise Refused, "#{label} doesn't loop: a morph blends looping generator clips (#{label}.loop loops it)" unless clip.looping? && clip.length > 0
            prods = clip.variations.select { |v| v.block.is_a?(Producer) }
            raise Refused, "#{label} plays several generators at once: a morph blends one generator into another" if prods.length > 1
            prod = prods.first&.block
            gen = prod.is_a?(Mapped) ? prod.generator : prod
            if gen.is_a?(Morph)
              raise Refused, "#{label} is already a morph: a morph blends two generators (three or more sides are not built yet)"
            end
            steer = gen&.steer
            params = steer ? steer.params : {}
            Side.new(
              clip: clip, producer: prod, keys: params.keys.freeze, params: params,
              unit: steer ? steer.unit : clip.length, lead: steer ? steer.lead : 0r,
              slots: gen ? gen.slots : Slots::BEAT, seed: gen ? gen.seed : clip.seed, label: label
            )
          end

          # A looping clip morphing from clip +a+ to clip +b+ by +morph+ (a
          # number from 0 to 1, or a knob or other param); +labels+ name
          # them in errors (their library paths).  Raises Refused for a
          # drum beat with a pitched line, cycle lengths where neither
          # divides the other, and morphs of morphs.
          def clip(a, b, morph:, labels: [a.to_s, b.to_s])
            sa = side(a, labels[0])
            sb = side(b, labels[1])
            check_pair(sa, sb)
            unless morph.is_a?(Numeric) || MIDI::Param.param?(morph)
              raise ArgumentError, "morph: is from 0 (#{labels[0]}) to 1 (#{labels[1]}), or a knob or other param (got #{morph.inspect})"
            end
            if morph.is_a?(Numeric) && !(morph.real? && morph.between?(0, 1))
              raise ArgumentError, "morph: is from 0 (#{labels[0]}) to 1 (#{labels[1]}) (got #{morph.inspect})"
            end
            gen = new(sa, sb, morph: morph)
            early = [a, b].map { |c| c.variations.sum(0r) { |v| v.early.to_r } }.max
            Sequence::Clip.new(gen.preview(0), length: gen.length, loop: true, seed: a.seed, align: a.instance_variable_get(:@align),
              variations: [Sequence::Clip::Variation.new(name: gen.name, block: gen, early: early)], values: (a.values + b.values).uniq)
          end

          # Raises Refused unless sides +a+ and +b+ can morph.
          def check_pair(a, b)
            if a.slots.by != b.slots.by
              drums, line = a.slots.by == :note ? [a, b] : [b, a]
              raise Refused, "#{drums.label} plays drum roles and #{line.label} plays pitches: a morph needs two of one kind; " \
                             'layer them on two tracks (track :drums, ...; track :lead, ...)'
            end
            long, short = [a.length, b.length].max, [a.length, b.length].min
            return if (long / short).denominator == 1

            raise Refused, "#{a.label} cycles every #{Sequence::Duration.format(a.length)}, #{b.label} every #{Sequence::Duration.format(b.length)}: " \
                           'a morph needs one cycle length to divide the other'
          end
        end

        # The sides (Side).
        attr_reader :sides

        # The morph's Steer key of side +i+'s param +name+ (:"a.energy",
        # :"b.swing"; plain Steer keys, not Session names).
        def self.key(i, name)
          :"#{SIDE_NAMES[i]}.#{name}"
        end

        # Side names in the morph's Steer keys.
        SIDE_NAMES = %w[a b].freeze

        # A morph from Side +a+ to Side +b+ by +morph+ (see .clip).
        def initialize(a, b, morph:)
          @sides = [a, b].freeze
          length = [a.length, b.length].max
          @counts = @sides.map { |s| (length / s.length).to_i }.freeze
          params = { morph: morph }
          @sides.each_with_index { |s, i| s.keys.each { |k| params[Morph.key(i, k)] = s.params[k] } }
          @fixed = params.freeze
          @side_keys = @sides.each_with_index.map { |s, i| s.keys.map { |k| [k, Morph.key(i, k)] }.freeze }.freeze
          unit = @sides.map(&:unit).min
          lead = @sides.map(&:lead).max
          name = "morph(#{a.label}, #{b.label})"
          steer = Steer.build(params, length: length, what: name, lead: lead, decide: unit >= length ? :cycle : unit)
          reach = @sides.each_with_index.map { |s, i| (@counts[i] - 1) * s.length + side_reach(s) }.max
          @dice = Dice.new(a.seed, :morph, b.seed)
          @hold = @sides.map { |s| s.slots.hold }.max
          super(length, seed: a.seed, name: name, reach: MB::M.max(reach, length), steer: steer, slots: a.slots) { |cycle, _dice, **values|
            cycle_events(cycle, values.empty? ? @fixed : values)
          }
        end

        # The events of morph cycle +cycle+ with the decided +values+
        # (:morph, and each side's params by "a.name", "b.name"): each slot's events
        # from A or from B (see the class comment), A's in A's order, then
        # B's in B's order.
        def cycle_events(cycle, values)
          t = values[:morph].to_f.clamp(0.0, 1.0)
          lists = @sides.each_index.map { |i| side_events(i, cycle, values) }
          # (the ends: one side whole, as it plays alone)
          return lists[0] if t <= 0.0 && no_anchors?
          return lists[1] if t >= 1.0

          keys = lists.each_with_index.map { |list, i| slot_keys(list, @sides[i].slots) }
          b_slots = keys[1].to_h { |k| [k, true] }
          block = cycle.div(@hold)
          out = []
          lists[0].each_with_index { |e, j| out << e unless b_side?(keys[0][j], t, block, b_slots, true) }
          a_slots = keys[0].to_h { |k| [k, true] }
          lists[1].each_with_index { |e, j| out << e if b_side?(keys[1][j], t, block, a_slots, false) }
          out
        end

        private

        # True when no side has anchors (anchors switch at 0.5, so morph 0
        # is A whole either way; this only skips the slot work).
        def no_anchors?
          @sides.all? { |s| s.slots.anchors.nil? }
        end

        # Side +i+'s events over morph cycle +cycle+ (its cycles in turn
        # when shorter, moved to their place in the morph cycle).
        def side_events(i, cycle, values)
          s = @sides[i]
          vals = @side_keys[i].empty? ? nil : @side_keys[i].to_h { |k, key| [k, values[key]] }.freeze
          n = @counts[i]
          return s.events(cycle, vals) if n == 1
          (0...n).flat_map { |j|
            list = s.events(cycle * n + j, vals)
            j == 0 ? list : list.map { |e| e.with(start: e.start + j * s.length) }
          }
        end

        # The slot of each event of +list+ (see Slots): [note, step start,
        # nth hit of the note there] by note, the beat's index by beat.
        def slot_keys(list, slots)
          grid = slots.grid
          if slots.by == :note
            seen = Hash.new(0)
            list.map { |e|
              pos = (e.start / grid).floor * grid
              k = [e.value, pos]
              [e.value, pos, seen[k] += 1].freeze
            }
          else
            list.map { |e| (e.start / grid).floor }
          end
        end

        # True if the slot +key+ plays B's version at morph +t+ in hold
        # block +block+ (+other+ the other side's slots, +a_side+ true when
        # asked for A's event).
        def b_side?(key, t, block, other, a_side)
          if anchor?(key)
            return false if t < 0.5
            return true if t > 0.5
            # (at the middle a slot only one side anchors keeps its hit)
            return a_side ? other.key?(key) : true
          end
          t >= tau(key, block)
        end

        # True for a drum slot either side anchors.
        def anchor?(key)
          return false unless key.is_a?(Array)
          @sides.any? { |s| s.slots.anchors&.key?([key[0], key[1]]) }
        end

        # The slot's threshold in (0, 1] (both seeds, the hold block, the
        # slot).
        def tau(key, block)
          key.is_a?(Array) ? 1.0 - @dice.rand(block, dice_key(key[0]), key[1], key[2]) : 1.0 - @dice.rand(block, key)
        end

        def dice_key(value)
          value.is_a?(Integer) || value.is_a?(Rational) ? value : value.to_s
        end

        # How late side +s+'s events may end, in whole notes from its
        # cycle's start.
        def side_reach(s)
          return 2 * s.length unless s.producer
          s.producer.reach_cycles * s.length
        end

        # (each side's events in that side's own order; see the class
        # comment)
        def order(list)
          i = -1
          list.sort_by { |e| [e.start, i += 1] }
        end
      end
    end

    # Clip#morph (see Library::Generators::MorphMethods#morph).
    Sequence::Clip.include(Library::Generators::MorphMethods)
  end
end
