module MB
  module Sound
    module Library
      # A shelf the library reads entries from: +name+ (:session, :env,
      # :project, :user, :gem, :builtin), +dir+ (its directory, or nil for
      # the class presets and the Session's racks), and +label+ (for
      # listings: "project /x/presets", "gem my-sounds").  Shelves are
      # searched in SHELF_ORDER; the first match wins.
      Shelf = Data.define(:name, :dir, :label) do
        def initialize(name:, dir: nil, label: nil)
          raise ArgumentError, "Unknown shelf #{name.inspect} (#{SHELF_ORDER.join(', ')})" unless SHELF_ORDER.include?(name)
          super(name: name, dir: dir&.then { File.expand_path(_1).freeze }, label: (label || [name, dir].compact.join(' ')).to_s.freeze)
        end

        # The shelf's place in the search order (0 first).
        def rank = SHELF_ORDER.index(name)

        # True for the shelves that ship with mb-sound (the class presets
        # and mb-sound's own presets/): collisions there are errors (a
        # guard spec checks every shipped entry).
        def shipped? = name == :builtin

        def to_s = label
        def inspect = "#<Library::Shelf #{label}>"
      end

      # Search order of the shelves: the Session's named racks (live
      # definitions), $MB_SOUND_PRESETS, the project's presets/ (the song
      # or album around the working directory), the user shelf (a git
      # repository that every save commits to), gems that name a shelf
      # in their metadata, then mb-sound's built-ins (class presets and
      # its presets/ folder).
      SHELF_ORDER = %i[session env project user gem builtin].freeze

      # What an entry is, musically: its scale.  Each kind has a head
      # under MB::Sound::L (see HEADS).
      KINDS = %i[instrument effect note_fx listener modulator kit clip master set envelope sample_edit].freeze

      # One library entry: a frozen value describing something you can
      # find and use by name (maintainer's library design, 2026-10-24:
      # "presets at every scale").
      #
      # - +name+ (a Symbol) is unique within its +family+ on one shelf
      # - +kind+ is the scale (KINDS): what the head L.inst, L.fx, ...
      #   lists
      # - +family+ is the namespace the name lives in and the verb that
      #   builds it: :reverb (`sig.reverb(:hall)`), :chorus, :resonator,
      #   :envelope, :env_curve, :lofi, :squeeze, :mastering, :sq80,
      #   :machine (tr808, tr909), :genre_patch, :clip, and :preset for
      #   everything `preset :x` loads (graph documents, rack documents,
      #   library-file instruments and chains, the Session's named racks)
      # - +tags+ (frozen Symbols) are free-form adjectives and roles
      #   ("tags as adjectives or roles, names as nouns")
      # - +facets+ (a frozen Hash) is reserved for facet values once their
      #   vocabularies are decided (empty for now)
      # - +about+ is a one-line description
      # - +params+ ({ name => MB::Sound::Param }) the entry's settings
      #   that can be changed when it is used
      # - +shelf+ (a Shelf) and +location+ ("file:line", or a path) say
      #   where it came from
      # - +settings+ is a family preset's frozen settings Hash (nil for
      #   other entries)
      # - +builder+ makes the thing: `entry.(sig)`, `entry.(midi)`, with
      #   the family's arguments (nil for entries that only hold data)
      # - +source+ is the entry's own Ruby (a library file's statement, or
      #   nil): what collect and promote copy
      # Params of entries made when first read (see Entry#params).
      LAZY_PARAMS = ObjectSpace::WeakKeyMap.new

      Entry = Data.define(:name, :kind, :family, :tags, :facets, :about, :params, :shelf, :location, :settings, :builder, :source) do
        def initialize(name:, kind:, family:, tags: [], facets: {}, about: nil, params: {}, shelf: nil, location: nil, settings: nil, builder: nil, source: nil)
          raise ArgumentError, "Entry names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
          raise ArgumentError, "Unknown entry kind #{kind.inspect} (#{KINDS.join(', ')})" unless KINDS.include?(kind)
          raise ArgumentError, "Entry families are Symbols (got #{family.inspect})" unless family.is_a?(Symbol)
          tags = Array(tags).map { |t|
            raise ArgumentError, "#{name}: tags are words (Symbols or Strings; got #{t.inspect})" unless t.is_a?(Symbol) || t.is_a?(String)
            t.to_s.downcase.tr(' -', '__').to_sym
          }.uniq.freeze
          raise ArgumentError, "#{name}: facets: is a Hash (got #{facets.inspect})" unless facets.is_a?(Hash)
          raise ArgumentError, "#{name}: about: is a String (got #{about.inspect})" unless about.nil? || about.is_a?(String)
          unless params.respond_to?(:call) || (params.is_a?(Hash) && params.all? { |k, v| k.is_a?(Symbol) && v.is_a?(MB::Sound::Param) })
            raise ArgumentError, "#{name}: params: is { name => MB::Sound::Param } (or a Proc making one when first read)"
          end
          super(
            name: name, kind: kind, family: family, tags: tags, facets: facets.dup.freeze, about: about&.dup&.freeze,
            params: params.respond_to?(:call) ? params : params.dup.freeze, shelf: shelf || Library.builtin_shelf, location: location&.to_s&.freeze,
            settings: settings && Library.deep_freeze(settings), builder: builder, source: source&.dup&.freeze
          )
        end

        # The params ({ name => MB::Sound::Param }; made when first read for
        # class presets, whose declarations may name units that load after
        # them).
        alias_method :raw_params, :params
        def params
          p = raw_params
          return p unless p.respond_to?(:call)
          LAZY_PARAMS[self] ||= p.call.freeze
        end

        # Makes the thing the entry names: a family preset applied to its
        # input (`entry.(sig)`, `entry.(midi)`), a graph document or rack
        # loaded with inputs and params as keywords, a clip.  Raises for
        # entries without a builder.
        def call(*args, **kwargs, &block)
          raise ArgumentError, "#{label} holds data only (nothing to build)" unless builder
          Library.index.note_use(self)
          builder.call(*args, **kwargs, &block)
        end
        alias_method :[], :call

        # The words that narrow a search to this entry under its kind's
        # head: its family (when it isn't :preset) and its tags.
        def words
          (family == :preset ? tags : [family, *tags]).uniq
        end

        # Name words ("dnb_reese" => [:dnb, :reese]).
        def name_words
          name.to_s.split('_').reject(&:empty?).map(&:to_sym)
        end

        # The head path that reaches it: "L.fx.hall" when the name is
        # unique under its head, else with the family ("L.fx.reverb.plate").
        def head_path
          head = HEADS.key(kind)
          same = Library.index.entries(kind: kind).count { |e| e.name == name }
          [*(head ? ['L', head] : ['L.all']), (family if same > 1 && family != :preset), name].compact.join('.')
        end

        # A Proc calling the entry (`sig.then(&L.fx.hall)`).
        def to_proc
          method(:call).to_proc
        end

        # Strikes a resonator once (a resonator effect or a struck
        # instrument; see MB::Sound::Struck): `L.fx.bar.ping(C5)`,
        # `L.fx.bell.ping(C4, E4, G4)` (a chord), `L.inst.bowl.ping` (its
        # typical pitch).  Returns the graph (it ends when the ring does).
        def ping(*pitches)
          MB::Sound::Struck.ping(self, pitches)
        end

        # What `play entry` plays (see MB::Sound::Playable): an instrument
        # on a demo phrase (struck ones near their typical pitch), a kit's
        # voices once each, a resonator effect's strike; other effects
        # raise with how to use them.
        def to_playable
          Library::Audition.playable(self)
        end

        # The graph the entry plays on its Listening Bench +material+ (see
        # Library::Bench): an effect on :arp (default), :break, or :pad; an
        # instrument on its role's phrases (`L.inst.dnb_reese.audition`,
        # `.audition(:template)`, its genre template's phrase); a kit on
        # :drums_beat or :drums_busy.  Finite, so `play` ends by itself:
        # `play L.fx.reverb.hall.audition(:break)`.
        def audition(material = nil)
          Library::Bench.graph(self, material)
        end

        # The materials #audition takes for this entry.
        def auditions = Library::Bench.materials_for(self).map(&:key)

        # Renders a Listening Bench set of this entry (see Library::Bench.run
        # for the options): `L.fx.reverb.hall.bench`.
        def bench(**options)
          Library::Bench.run(self, **options)
        end

        # A label for messages: "reverb :hall" or "preset :dnb_reese".
        def label
          "#{family} #{name.inspect}"
        end

        # The Ruby that uses it (the family's code form), e.g.
        # "sig.reverb(:hall)" or "preset(:dnb_reese, midi: midi)".
        def to_ruby
          f = Library.families[family]
          f&.code ? f.code.call(self) : "#{family}(#{name.inspect})"
        end

        # True if +other+ describes the same thing (name, family, kind,
        # tags, about, settings, source): a pinned copy in a song's shelf
        # equals the entry it was collected from.
        def same_as?(other)
          other.is_a?(Entry) && [name, family, kind, tags, about] == [other.name, other.family, other.kind, other.tags, other.about] &&
            MB::Sound::Param.value_key(settings) == MB::Sound::Param.value_key(other.settings) &&
            (source.nil? || other.source.nil? || source == other.source)
        end

        def to_s
          extra = tags.empty? ? '' : " [#{tags.join(', ')}]"
          "#{name} (#{kind}, #{family})#{extra} #{shelf.name}"
        end

        def inspect
          "#<Library::Entry #{self}>"
        end
      end

      # A family of entries (see Entry): +name+ (the verb in library files,
      # e.g. :reverb), +kind+, +about+, +owner+ (the class or module whose
      # presets they are, or nil), +apply+ (how a family preset is used:
      # called with the entry name and the arguments of Entry#call), and
      # +code+ (prints an entry's code form from the entry).
      Family = Data.define(:name, :kind, :about, :owner, :apply, :code) do
        def initialize(name:, kind:, about: nil, owner: nil, apply: nil, code: nil)
          raise ArgumentError, "Unknown entry kind #{kind.inspect} (#{KINDS.join(', ')})" unless KINDS.include?(kind)
          super
        end
      end
    end
  end
end
