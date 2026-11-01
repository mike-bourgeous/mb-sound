module MB
  module Sound
    module Library
      # Generators in the library (lib-gen-1, 2026-10-31; the maintainer:
      # "I'd like our existing generators from demos and songs to be in the
      # library as generators", heads "L.gen + L.flow (rename form to flow)
      # for now"): clip generators (kind and family :generator, under
      # L.gen: motifs, beats, strikes, melodies, generate blocks, the note
      # material for a track) and section chains (kind and family :flow,
      # under L.flow: markov and lsystem sources that drive a flow).
      #
      #     L.gen.techno_beat                                  # the Entry
      #     L.gen.techno_beat(seed: 3, energy: knob(:energy))  # its Clip
      #     L.gen.techno_beat.()                               # the Clip at the entry's defaults
      #     track :drums, L.gen.techno_beat                    # on its kit (the TR-909)
      #     track :lead, L.gen.phrygian_motif, :tine_piano     # on another instrument
      #     flow L.flow.techno_chain                           # the chain over this session's scenes
      #     L.flow.techno_chain(seed: 4)                       # the chain, reseeded
      #
      # Each entry's builder runs its block with the entry's params (Params
      # with defaults; given keywords replace them, unknown ones raise with
      # did-you-mean), and records the call on what it built, so recipes,
      # graph documents, set documents, and template code print it back
      # as `L.gen.techno_beat(seed: 3, energy: energy)` (or
      # `L.gen.techno_beat.()` at the defaults) and load it again (the
      # loader walks `L.gen`/`L.flow` chains, GraphIO::Registry).
      #
      # Shipped generators are defined in code beside what plays them (the
      # genre templates' chains and clips in lib/mb/sound/genre/*.rb, the
      # demo songs' in lib/mb/sound/library/generators/*.rb), so the
      # templates and scripts read them from the library: one source.
      # Library files hold the user's (`generator :x do |seed: 1| ... end`,
      # `flow :x, bars: { ... } do |seed: 1| markov(...) end`; FileLoader).
      module Generators
        # The receiver of a recorded entry call, printed as its text
        # ("L.gen" in `L.gen.techno_beat(seed: 3)`; RubyWriter and
        # RubyValue print it; the graph document loader reads the chain
        # back through the heads).
        Path = Data.define(:text) do
          def to_s = text
          def inspect = text
          def to_ruby = text
        end

        # What an entry call built (see .origin): the +entry+ and the
        # keywords it was given.
        Built = Data.define(:entry, :kwargs)

        # Descriptions of params by name (an entry's own +describe:+ wins).
        DESCRIPTIONS = {
          seed: 'The seed of the draws (another seed, another line)',
          harmony: 'The probability scale the notes are drawn from (Weights, a Harmony, a Field)',
          scale: 'The scale the notes walk',
          energy: 'How busy: 0 nearly nothing, 0.5 as written, 1 everything (read once a cycle)',
          density: 'How many steps start a note (read once a cycle)',
          mutate: 'How far the motifs drift from their first form (read once a cycle)',
          vary: 'How much repeats within a pass vary',
          range: 'The register',
          around: 'The note the line centers on',
          chance: 'The chance of a strike on each step',
          blur: 'How far the scale blurs into wrong notes',
          leap: 'The largest move, in scale steps',
        }.freeze

        # Clips built by entries => Built (keys weak: an entry call never
        # keeps what it built alive; values strong: an ObjectSpace::WeakMap
        # would let the Built go at the next GC; clips compare by identity).
        # Sources keep theirs in @origin (they compare by their chains).
        ORIGINS = ObjectSpace::WeakKeyMap.new

        # The repository root, for entry locations.
        ROOT = File.expand_path('../../../..', __dir__)

        # Note names (A3, Fs2) in code inside a module of its own, as
        # MB::Sound itself resolves them: `extend NoteNames` (Ruby asks the
        # innermost module of the code for a missing constant).
        module NoteNames
          def const_missing(name)
            return super unless name != :Note && MB::Sound::Note.name?(name)
            MB::Sound.const_get(name)
          end
        end
        extend NoteNames

        module_function

        # Registers a clip generator +name+ (an L.gen entry): +block+ takes
        # the params as keywords and returns a Clip.  +params+ is a Proc
        # (run in MB::Sound once, when the params are first read) giving
        # { name => default } (`(0.0..1.0).at(0.5)` for a ranged one);
        # +describe+ overrides DESCRIPTIONS; +instrument+ (an instrument or
        # kit name, e.g. :tr909) is what plays it on a track given no other
        # and in `play`/`audition`.
        def generator(name, tags: [], about: nil, instrument: nil, params: -> { {} }, describe: {}, &block)
          define(:generator, name, tags: tags, about: about, params: params, describe: describe, settings: { instrument: instrument }, block: block)
        end

        # Registers a section chain +name+ (an L.flow entry): +block+ takes
        # the params as keywords and returns a markov or lsystem over
        # section names; +bars+ gives each section's length per occurrence
        # (bars, Ranges, Arrays), +sections+ how many a finite play draws
        # when the chain doesn't end, +genre+ the template whose scenes it
        # plays.
        def flow(name, bars:, sections: nil, genre: nil, tags: [], about: nil, params: -> { {} }, describe: {}, &block)
          define(:flow, name, tags: tags, about: about, params: params, describe: describe,
                 settings: { bars: bars, sections: sections, genre: genre }, block: block)
        end

        # Registers an entry of +kind+ (see .generator and .flow).
        def define(kind, name, tags:, about:, params:, describe:, settings:, block:)
          raise ArgumentError, "#{kind} #{name.inspect} needs a block" unless block
          file, line = block.source_location
          Library.index.register(entry(
            kind, name, tags: tags, about: about, location: "#{file.delete_prefix("#{ROOT}/")}:#{line}",
            params: -> { declare(MB::Sound.instance_exec(&params), describe) }, settings: settings, block: block
          ))
        end

        # An Entry of +kind+ (:generator or :flow) building with +block+
        # (see .run); +params+ is { name => Param } or a Proc making it;
        # the rest as Entry.new takes it.
        def entry(kind, name, params:, settings:, block:, **rest)
          built = nil
          builder = ->(*args, **kw, &b) { run(built, block, args, kw, b) }
          built = Entry.new(name: name, kind: kind, family: kind, params: params, settings: settings.compact, builder: builder, **rest)
          BLOCKS[built] = block
          built
        end

        # Each entry's block (Entry => block, keys weak), for builds with
        # track knobs (.track_clip).
        BLOCKS = ObjectSpace::WeakKeyMap.new

        # +kwargs+ with +entry+'s seed written out (its default, first)
        # when it has a seed param and +kwargs+ gives none.
        def with_seed(entry, kwargs)
          seed = entry.params[:seed]
          return kwargs if seed.nil? || kwargs.key?(:seed)
          { seed: seed.default }.merge(kwargs)
        end

        # The params of generator Entry +entry+ that a track playing it
        # gets as knobs (the maintainer, 2026-11-02: "Yes", generator
        # params become track knobs like preset params): numeric params
        # with a bounded range and a number default (`energy: (0.0..1.0).at(0.5)`),
        # the options the generators read once a cycle (energy, density,
        # mutate, chance, ...).  Values (harmonies, scales, chords),
        # structure (grids, divisions), seeds, and plain-number params
        # stay as they are.  Library file generators' ranged params too
        # (`param :energy, (0.0..1.0).at(0.5)`).
        def knob_params(entry)
          return [] unless entry.kind == :generator
          entry.params.filter_map { |k, p|
            k if k != :seed && p.numeric? && p.bounded? && p.default.is_a?(Numeric) && p.range.begin.is_a?(Numeric)
          }
        end

        # +value+ (a generator Entry, a clip one built, or anything else)
        # as track +track+ of +session+ plays it: the entry's clip (at its
        # defaults, or with the keywords the call gave) with the session
        # knobs :"track/param" steering the .knob_params the call didn't
        # give (Arrangement::TrackKnobs.knob_for: made at the param's value
        # with its range, or reused), so `track :drums, L.gen.techno_beat`
        # turns with :"drums/energy" and renders like the plain values
        # until it is turned.  +reuse+ (scenes, bg, swap) keeps an existing
        # knob as it is instead of TrackKnobs' rules for a track's new
        # build (a scene defined while another generator plays on the
        # track doesn't move its knobs).  Other values, entries without
        # such params, and calls that gave all of them come back as they
        # are (entries built at their defaults).  The same call on the
        # same track gives the same clip (remembered per Session), so a
        # scene and the track's own clip are one slot.
        def track_clip(value, track, session, reuse: false)
          entry, given =
            case value
            when Entry
              return value unless value.kind == :generator && value.builder
              [value, {}]
            when Sequence::Clip
              b = ORIGINS[value] or return value
              [b.entry, b.kwargs]
            else
              return value
            end
          free = knob_params(entry) - given.keys
          ok = session && track.is_a?(Symbol) && !track.to_s.include?('/') && BLOCKS[entry]
          return value.is_a?(Entry) ? value.call : value if free.empty? || !ok

          knobs = free.to_h { |k|
            param = entry.params[k]
            kname = Session::Name.param(track, k)
            [k, (reuse && session.knobs[kname]) || Arrangement::TrackKnobs.knob_for(session, track, param)]
          }
          return value.is_a?(Entry) ? value.call : value if knobs.value?(nil) # (a knob name taken by something else)

          cache = (track_clips[session] ||= {})
          key = [track, entry.name, entry.location]
          hit = cache[key]
          return hit[2] if hit && hit[0] == given && hit[1].all? { |k, kn| knobs[k].equal?(kn) } && hit[1].length == knobs.length

          clip = run(entry, BLOCKS[entry], [], given, knobs: knobs)
          KNOBS[clip] = knobs.freeze
          cache[key] = [given, knobs, clip]
          clip
        end

        # Clips .track_clip built => { param => knob } (keys weak).
        KNOBS = ObjectSpace::WeakKeyMap.new

        # The track knobs steering +clip+ ({ param => GraphNode::Knob },
        # from .track_clip; the inspector's row for the clip), or nil.
        def knobs_of(clip)
          KNOBS[clip]
        end

        # The clips .track_clip built per Session ({ Session => { [track,
        # entry name, location] => [given, knobs, clip] } }, weak).
        def track_clips
          @track_clips ||= ObjectSpace::WeakKeyMap.new
        end

        # Runs the block with +values+' moving params (knobs, ccs) for
        # +params+ remembered as having the params' defaults for their
        # home (see .home).
        def with_homes(params, values, &block)
          homes = nil
          values.each do |k, v|
            next unless MIDI::Param.param?(v)
            d = params[k]&.default
            next unless d.is_a?(Numeric)
            (homes ||= {}.compare_by_identity)[v] = d
          end
          return yield unless homes
          Internal.with_local(:mb_sound_generator_homes, homes) { yield }
        end

        # The default of the generator param that moving param +param+
        # steers in the entry building now (a knob given for density: in
        # `L.gen.ambient_motif(density: knob(:busy))`, or a track's
        # :"lead/density"), or nil.  Generators whose steered path works
        # around a home value read it (motifs' density thins and fills
        # around it), so a knob at the entry's default plays what the
        # plain default plays.
        def home(param)
          Thread.current[:mb_sound_generator_homes]&.[](param)
        end

        # { name => Param } for +defaults+ ({ name => default }).
        def declare(defaults, describe = {})
          defaults.to_h { |k, v|
            [k, MB::Sound::Param.declare(k, v, description: describe[k] || DESCRIPTIONS[k])]
          }
        end

        # Builds +entry+ with +kwargs+ (keywords only): runs +block+ (a
        # Ruby block taking every param as a keyword, or a library file's
        # walked block) with the params' defaults and the given values,
        # recording the call on the result (see the module comment).  The
        # call records its seed written out (the maintainer, 2026-11-02:
        # "Write the seed"): `L.gen.techno_beat.()` prints back as
        # `L.gen.techno_beat(seed: 5)`.  +knobs+ ({ param => knob }, from
        # .track_clip) steer the params a track gives knobs to: the block
        # gets them, the call records only +kwargs+ (a track gives the
        # knobs again when it plays the call).
        def run(entry, block, args, kwargs, given_block = nil, knobs: nil)
          path = head_path(entry)
          raise ArgumentError, "#{path} takes its params as keywords (#{keys_text(entry)}); got #{args.length} positional" unless args.empty?
          raise ArgumentError, "#{path} takes no block" if given_block
          params = entry.params
          unknown = kwargs.keys - params.keys
          unless unknown.empty?
            raise ArgumentError, "#{path}: unknown keyword#{'s' if unknown.length > 1} #{unknown.map { |k| "#{k}:" }.join(', ')} " \
              "(it takes #{keys_text(entry)})#{Library.suggest(unknown[0], params.keys).gsub(/:(\w+)/, '\1:')}"
          end
          kwargs = with_seed(entry, kwargs)
          values = params.transform_values(&:default).merge(kwargs)
          values.merge!(knobs) if knobs
          receiver, word = split_path(path)
          result = GraphNode::Recipe.call(receiver, word, [], kwargs, nil) {
            with_homes(params, values) { MB::Sound.instance_exec(**values, &block) }
          }
          check_result(entry, result)
          built = Built.new(entry, kwargs.dup.freeze)
          if entry.kind == :flow
            result.instance_variable_set(:@origin, built)
          else
            ORIGINS[result] = built
          end
          result
        end

        # Raises unless +result+ is what +entry+'s kind builds.
        def check_result(entry, result)
          if entry.kind == :generator
            return if result.is_a?(Sequence::Clip)
            raise ArgumentError, "generator #{entry.name.inspect} (#{entry.location}) built #{result.class}, not a clip"
          end
          return if result.respond_to?(:form_next) && result.respond_to?(:reseed)
          raise ArgumentError, "flow #{entry.name.inspect} (#{entry.location}) built #{result.class}, not a markov(...) or lsystem(...)"
        end

        # [Path of the head, word] of +path+ ("L.gen.techno_beat").
        def split_path(path)
          head, _, word = path.rpartition('.')
          [Path.new(head), word.to_sym]
        end

        # The entry's head path (remembered per entry: a head path reads
        # the index).
        def head_path(entry)
          (@paths ||= ObjectSpace::WeakKeyMap.new)[entry] ||= entry.head_path.freeze
        end

        # "seed:, energy:" for +entry+'s params.
        def keys_text(entry)
          entry.params.keys.map { |k| "#{k}:" }.join(', ').then { |t| t.empty? ? 'no params' : t }
        end

        # What built +obj+ (a Built), or nil.
        def origin(obj)
          return obj.instance_variable_get(:@origin) if obj.respond_to?(:form_next)
          obj.is_a?(Sequence::Clip) ? ORIGINS[obj] : nil
        end

        # The instrument name a generator clip's entry plays on (see
        # .generator), or nil.
        def instrument(clip)
          origin(clip)&.entry&.settings&.[](:instrument)
        end

        # The section lengths a flow source's entry gives (see .flow), or nil.
        def bars(source)
          b = source.is_a?(Entry) ? source : origin(source)&.entry
          b&.kind == :flow ? b.settings[:bars] : nil
        end

        # The source +x+ stands for: a flow Entry built at its defaults, or
        # +x+.
        def source(x)
          x.is_a?(Entry) && x.kind == :flow ? x.call : x
        end

        # Ruby for what +built+ built: `L.flow.techno_chain(seed: 4)` (the
        # seed written out at its default too: .with_seed), or
        # `L.flow.x.()` for an entry without params given or a seed;
        # +value_text+ prints the keyword values (knobs by their label).
        def call_text(built, &value_text)
          value_text ||= ->(v) { MIDI::Param.param?(v) ? MIDI::Param.label(v) : RubyValue.to_ruby(v, gains: true) }
          path = head_path(built.entry)
          kwargs = with_seed(built.entry, built.kwargs)
          return "#{path}.()" if kwargs.empty?
          "#{path}(#{kwargs.map { |k, v| "#{k}: #{value_text.call(v)}" }.join(', ')})"
        end

        # Ruby for +entry+ built at its defaults: `L.gen.techno_beat(seed:
        # 5)` (the family's code form; `L.gen.x.()` without a seed param).
        def default_call_text(entry)
          call_text(Built.new(entry, {}.freeze))
        end

        # A copy of +source+ (a flow entry's build) reseeded with +seed+,
        # remembering the entry with the new seed (so it prints as
        # `L.flow.techno_chain(seed: 4)`); other sources as #reseed makes
        # them.
        def reseeded(source, copy, seed)
          built = source.instance_variable_get(:@origin)
          return copy unless built && built.entry.params.key?(:seed)
          kw = built.kwargs.merge(seed: seed)
          copy.instance_variable_set(:@origin, Built.new(built.entry, kw.freeze))
          copy
        end

        ### play and audition

        # Bars a generator plays for `play`/`audition`.
        DEMO_BARS = 8

        # Sections of a chain's sketch (`play L.flow.x`).
        SKETCH_SECTIONS = 12

        # Chords a sketch gives sections in order of first appearance (A
        # minor: i, VI, III, VII, iv, v), so a section that comes back is
        # heard coming back.
        SKETCH_CHORDS = [%w[A3 C4 E4], %w[F3 A3 C4], %w[C4 E4 G4], %w[G3 B3 D4], %w[D4 F4 A4], %w[E4 G4 B4]].freeze

        # What `play` plays for a generator entry: its clip (at the entry's
        # defaults) on its instrument (else the soft saw, or a drum machine
        # for drum notes), DEMO_BARS bars.  Returns a Playable::Graph.
        def demo(entry)
          clip = entry.call
          path = head_path(entry)
          inst = entry.settings[:instrument]
          node = if inst
                   Arrangement::InstrumentPatch.entry_for(inst, track: :audition).call(clip)
                 else
                   Playable.graph(clip).nodes
                 end
          node = node.is_a?(Array) ? node : node.outputs
          limited = node.map { |n| n.until(DEMO_BARS.bars) }
          Playable::Graph.new(nodes: limited, description: "#{path} on #{inst || 'a soft saw'}, #{DEMO_BARS} bars", ends: true,
            note: "a generator makes note material: track :x, #{path}#{inst ? '' : ', :instrument'}; #{path}(seed: 2) for another line")
        end

        # What `play` plays for a flow entry: a sketch of the chain, one bar
        # per section for its first SKETCH_SECTIONS sections, each section
        # a chord of its own (a section that returns returns with its
        # chord) on the soft saw.  The description lists the sections with
        # their lengths.
        def sketch(entry)
          src = entry.call
          bars = entry.settings[:bars] || {}
          names = sketch_sections(src)
          chords = {}
          steps = names.map { |n|
            notes = chords[n] ||= SKETCH_CHORDS[chords.length % SKETCH_CHORDS.length].map { |x| MB::Sound::Note.new(x) }
            notes.map(&:n1).reduce(:&)
          }
          clip = MB::Sound.seq(*steps)
          lengths = names.map { |n| b = bars[n]; b ? "#{n} #{MB::Sound::RubyValue.to_ruby(b)}" : n.to_s }
          g = Playable.graph(clip)
          genre = entry.settings[:genre]
          path = head_path(entry)
          Playable::Graph.new(nodes: g.nodes, description: "#{path} sketched, a bar a section: #{lengths.join(', ')}", ends: true,
            note: genre ? "the template plays it: genre(#{genre.inspect}).generative.play (or .endless); flow #{path} after genre(#{genre.inspect}).setup" :
                          "a chain plays a flow over a set's scenes: flow #{path} (each section a scene of that name)")
        end

        # The first SKETCH_SECTIONS sections +src+ draws (a chain stops at
        # its end).
        def sketch_sections(src)
          lengths = src.form_states.reject { |s| src.nonterminal?(s) }.to_h { |s| [s, 1] }
          f = Form.build { generate src, bars: lengths }
          f.plan(seed: 0).first(SKETCH_SECTIONS).map(&:section)
        rescue StandardError
          src.respond_to?(:take) ? src.take(SKETCH_SECTIONS) : src.word.first(SKETCH_SECTIONS)
        end
      end

      index.define_family(:generator, kind: :generator, owner: Generators,
                                      about: 'Clip generators: note material for a track (L.gen.techno_beat(seed: 3))',
                                      code: ->(e) { Generators.default_call_text(e) })
      index.define_family(:flow, kind: :flow, owner: Generators,
                                 about: 'Section chains a flow plays (flow L.flow.techno_chain; generate L.flow.techno_chain.(), bars: ...)',
                                 code: ->(e) { Generators.default_call_text(e) })
    end
  end
end
