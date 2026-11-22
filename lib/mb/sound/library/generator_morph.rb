module MB
  module Sound
    module Library
      module Generators
        # Morphs of generators (gen-morph-1, 2026-11-22; the maintainer: "1
        # with morph also accepted as a parameter to set the initial knob
        # level, and make it work for all generators", and the line he
        # typed before it existed, `bg :drums,
        # L.gen.beat.dnb.morph(L.gen.beat.house)`): a chain method on a
        # generator entry or a clip one built, crossfading the two slot by
        # slot (Generative::Morph).
        #
        #     bg :drums, L.gen.beat.dnb.morph(L.gen.beat.house)   # knob :"drums/morph", 0 dnb .. 1 house
        #     bg :drums, L.gen.beat.rock.morph(:funk, morph: 0.3) # a name in the family; the knob starts at 0.3
        #     turn :"drums/morph", 1, over: 8.bars
        #     L.gen.morph(:rock, :funk)                           # the same as L.gen.beat.rock.morph(:funk)
        #
        # It prints and saves as the chain, `L.gen.beat.rock(seed:
        # 11).morph(L.gen.beat.funk(seed: 14))`.  On a track, the sides'
        # steering params the calls left out are the track's knobs (one
        # knob for a name both sides have, moving each side from its own
        # home; a knob only one side has steers that side), and a number
        # given for morph: is where the knob :"drums/morph" starts (a knob
        # turned since keeps its place; .morph_track_clip).
        module MorphMethods
          # A clip morphing from this generator into +other+ (a generator
          # entry, a clip one built, or a name: first in this entry's
          # family, `.morph(:house)`, then anywhere under L.gen) by
          # +morph:+ (0 this one, 1 the other: a number, where a track's
          # knob :"track/morph" starts, or a knob or other param).
          def morph(*others, **kwargs)
            Generators.morph(self, others, kwargs)
          end
        end

        # What a morph was made of (see .morph): the two side clips as
        # given and the morph: value.
        Morphed = Data.define(:sides, :morph)

        # Clips .morph made => Morphed (keys weak).
        MORPHS = ObjectSpace::WeakKeyMap.new

        # The morph param's description (a track's :"drums/morph" knob).
        MORPH_DESCRIPTION = 'Morph position: 0 the first generator, 1 the one it morphs into (read like the sides\' knobs)'

        module_function

        # What +clip+ morphs (a Morphed), or nil.
        def morph_of(clip)
          clip.is_a?(Sequence::Clip) ? MORPHS[clip] : nil
        end

        # True if +value+ is a clip a generator entry built or a morph of
        # generators (a track plays it with knobs: .track_clip).
        def generator_clip?(value)
          value.is_a?(Sequence::Clip) && !(origin(value) || MORPHS[value]).nil?
        end

        # The morph of +receiver+ (a generator Entry or a Clip) into the
        # one generator in +others+, with +kwargs+ (morph:), recorded as
        # `receiver.morph(other)` on the clip (see MorphMethods#morph).
        def morph(receiver, others, kwargs)
          path = receiver.is_a?(Entry) ? receiver.head_path : side_label(receiver)
          refuse_receiver(receiver, path) if receiver.is_a?(Entry)
          unknown = kwargs.keys - [:morph]
          unless unknown.empty?
            raise ArgumentError, "#{path}.morph: unknown keyword#{'s' if unknown.length > 1} #{unknown.map { |k| "#{k}:" }.join(', ')} " \
                                 "(it takes morph:, where the knob starts, 0 to 1; the sides take their own params: #{path}(energy: 0.8).morph(...))"
          end
          example = morph_example(receiver)
          if others.empty?
            raise ArgumentError, "#{path}.morph needs the generator to morph into: #{path}.morph(:#{example[1]}) or #{path}.morph(#{example[0]}.#{example[1]})"
          end
          if others.length > 1
            raise ArgumentError, "#{path}.morph takes one generator to morph into (got #{others.length}; three or more sides are not built yet): " \
                                 "#{path}.morph(:#{example[1]})"
          end
          a = receiver.is_a?(Entry) ? receiver.call : receiver
          b = morph_side(others.first, a, path)
          value = kwargs.fetch(:morph, 0.0)
          labels = [side_label(a), side_label(b)]
          GraphNode::Recipe.call(a, :morph, [b], kwargs, nil) {
            clip = Generative::Morph.clip(a, b, morph: value, labels: labels)
            MORPHS[clip] = Morphed.new(sides: [a, b].freeze, morph: value)
            clip
          }
        end

        # `L.gen.morph(a, b)`: +a+ (a name under L.gen, an entry, or a
        # clip) morphing into +b+, the same as `a.morph(b)` (and printed
        # so).
        def head_morph(query, args, kwargs)
          if args.length != 2
            raise ArgumentError, "#{query.path}.morph takes two generators (got #{args.length}): #{query.path}.morph(:rock, :funk), " \
                                 'the same as L.gen.beat.rock.morph(:funk)'
          end
          a = args.first
          a = resolve_name(a, nil, "#{query.path}.morph") if a.is_a?(Symbol)
          refuse_receiver(a, a.head_path) if a.is_a?(Entry)
          a = morph_side(a, nil, "#{query.path}.morph") unless a.is_a?(Entry)
          morph(a, [args[1]], kwargs)
        end

        # Raises for a receiver Entry that isn't a generator.
        def refuse_receiver(entry, path)
          return if entry.kind == :generator
          raise ArgumentError, "#{path}.morph: #{not_a_generator(entry, path)}"
        end

        # Why +entry+ (another kind) can't be morphed, and what to use.
        def not_a_generator(entry, path)
          case entry.kind
          when :flow then 'L.flow chains choose sections; morph blends note generators (L.gen): L.gen.beat.rock.morph(:funk)'
          when :effect then "morph blends generators (L.gen); effects mix with sig.blend (sig.blend(0.5) { it.then(&#{path}) })"
          when :kit, :instrument
            "#{path} is #{entry.kind == :kit ? 'a kit' : 'an instrument'}: morph blends generators (L.gen), and a track plays them on it " \
              "(track :drums, #{path}; bg :drums, L.gen.beat.rock.morph(:funk))"
          else "morph blends generators (L.gen), and #{path} is #{entry.kind == :clip ? 'a clip' : "a #{entry.kind}"}: L.gen.beat.rock.morph(:funk)"
          end
        end

        # [family path, another name in it] for examples ("L.gen.beat",
        # :funk for L.gen.beat.rock), from +receiver+ (an Entry or a clip).
        def morph_example(receiver)
          entry = receiver.is_a?(Entry) ? receiver : origin(receiver)&.entry
          return ['L.gen.beat', :funk] unless entry&.kind == :generator
          head, = split_path(head_path(entry))
          other = Library.index.entries(kind: :generator).find { |e| e.family == entry.family && e.name != entry.name }
          [head.text, other&.name || :funk]
        end

        # The clip +x+ stands for as the side a clip +a+ morphs into (an
        # Entry built at its defaults, a name resolved, a clip as it is);
        # raises with the working form for anything else.  +path+ names the
        # call in errors.
        def morph_side(x, a, path)
          case x
          when Sequence::Clip then x
          when Symbol then morph_side(resolve_name(x, a, path), a, path)
          when Entry
            raise ArgumentError, "#{path}.morph(#{x.head_path}): #{not_a_generator(x, x.head_path)}" unless x.kind == :generator
            x.call
          when Heads::Query
            raise ArgumentError, "#{path}.morph(#{x.path}): #{x.path} is #{x.size} entries (#{Heads.some_names(x)}); name one (#{x.path}.#{x.first&.name})"
          when Sequence::Kit
            raise ArgumentError, "#{path}.morph: a kit plays drums; morph blends two generators (L.gen): #{path}.morph(:#{morph_example(a)[1]})"
          else
            if x.respond_to?(:form_next)
              raise ArgumentError, "#{path}.morph: L.flow chains choose sections; morph blends note generators (L.gen)"
            end
            raise ArgumentError, "#{path}.morph takes a generator (an L.gen entry, a clip one built, or a name like :#{morph_example(a)[1]}; got #{x.inspect})"
          end
        end

        # The generator entry +name+ names for a morph of clip +a+ (or
        # nil): first in +a+'s entry's family (`L.gen.beat.dnb.morph(:house)`),
        # then under L.gen; raises with suggestions when nothing matches.
        def resolve_name(name, a, path)
          entry = a && origin(a)&.entry
          family = entry && entry.kind == :generator ? entry.family : nil
          pool = Library.index.entries(kind: :generator)
          found = family && pool.find { |e| e.family == family && e.name == name }
          return found if found

          begin
            hit = MB::Sound::L.gen.word(name)
          rescue KeyError => e
            names = (family ? pool.select { |x| x.family == family } : pool).map(&:name)
            raise ArgumentError, "#{path}.morph(#{name.inspect}): #{e.message.lines.first.chomp}#{Library.suggest(name, names)}"
          end
          hit
        end

        # A label for clip +clip+ in morph errors: its entry's path (a
        # morph's as its chain), else "the clip".
        def side_label(clip)
          m = morph_of(clip) and return "#{side_label(m.sides[0])}.morph(#{side_label(m.sides[1])})"
          b = clip.is_a?(Sequence::Clip) ? origin(clip) : nil
          b ? head_path(b.entry) : (clip.is_a?(Sequence::Clip) ? 'the clip' : clip.inspect)
        end

        # The morph param: :morph from 0 to 1, starting at +start+.
        def morph_param(start)
          MB::Sound::Param.declare(:morph, (0.0..1.0).at(start.to_f), description: MORPH_DESCRIPTION)
        end

        # Ruby for the param that moves a side whose home for a shared
        # knob is +home+ while the knob sits at +knob_home+ (the first
        # side's home): +home+ + (knob - +knob_home+), exactly +home+ while
        # the knob is untouched.
        def offset_param(knob, knob_home, home)
          MIDI::Param::Expr.new(:+, MIDI::Param::Const.new(home), MIDI::Param::Expr.new(:-, knob, knob_home))
        end

        # .track_clip for morph +value+ (made of +m+, a Morphed): the sides
        # built with the track's knobs for the params their calls left out
        # (a name both sides have is one knob, at the first side's home;
        # the other side moves from its own home by as much), and the
        # morph steered by the knob :"track/morph" when morph: was a
        # number (where the knob starts: made there, or placed there when
        # untouched; a turned knob keeps its place).  The same morph on the
        # same track gives the same clip.
        def morph_track_clip(value, m, track, session, reuse)
          return value unless session && track.is_a?(Symbol) && !track.to_s.include?('/')

          homes = {}
          shared = {}
          side_knobs = m.sides.map { |side|
            b = origin(side)
            next({}) unless b && BLOCKS[b.entry]
            (knob_params(b.entry) - b.kwargs.keys).to_h { |k|
              param = b.entry.params[k]
              home = param.default.to_f
              if shared.key?(k)
                [k, home == homes[k] ? shared[k] : offset_param(shared[k], homes[k], home)]
              else
                kname = Session::Name.param(track, k)
                knob = (reuse && session.knobs[kname]) || Arrangement::TrackKnobs.knob_for(session, track, param)
                return value if knob.nil? # (a knob name taken by something else)
                homes[k] = home
                shared[k] = knob
                [k, knob]
              end
            }
          }
          mvalue = m.morph
          if mvalue.is_a?(Numeric)
            mvalue = Arrangement::TrackKnobs.knob_for(session, track, morph_param(m.morph)) or return value
            shared[:morph] = mvalue
          end
          return value if shared.empty?

          cache = (track_clips[session] ||= {})
          key = [track, :morph, *m.sides.map { |s| b = origin(s); b ? [b.entry.name, b.entry.location, b.kwargs] : s.object_id }, m.morph.is_a?(Numeric) ? :knob : m.morph.object_id]
          hit = cache[key]
          return hit[2] if hit && hit[1].length == shared.length && hit[1].all? { |k, kn| shared[k].equal?(kn) }

          sides = m.sides.each_with_index.map { |s, i|
            next s if side_knobs[i].empty?
            b = origin(s)
            run(b.entry, BLOCKS[b.entry], [], b.kwargs, knobs: side_knobs[i])
          }
          clip = Generative::Morph.clip(*sides, morph: mvalue, labels: m.sides.map { |s| side_label(s) })
          MORPHS[clip] = m
          # (prints as the morph it was given: GIVEN, set documents)
          GraphNode::Recipe.share_record(value, clip)
          KNOBS[clip] = shared.freeze
          GIVEN[clip] = value
          cache[key] = [nil, shared, clip]
          clip
        end
      end

      # `L.gen.morph(:rock, :funk)` (see Generators.head_morph): accepted on
      # the generators' head, printed as the chain.
      module Heads
        module QueryMorph
          def morph(*args, **kwargs)
            return Generators.head_morph(self, args, kwargs) if kind == :generator && chosen.empty?
            raise ArgumentError, "#{path}.morph: morph is a chain method on a generator: L.gen.beat.rock.morph(:funk) " \
                                 '(or L.gen.morph(:rock, :funk))'
          end
        end
        Query.include(QueryMorph)
      end

      # (clips get it in generative/morph.rb: Library loads before Sequence)
      Entry.include(Generators::MorphMethods)
    end
  end
end
