module MB
  module Sound
    module Meta
      # An object's metadata as a value (metadata-2, 2026-11-11; the
      # maintainer: "a metadata helper/object/module/mixin/whatever built
      # around Ruby-centric ideas like Hash and Struct"): a frozen,
      # Hash-backed value in the style of Data, with readers for a small
      # vocabulary and any other plain-Ruby keys beside it.
      #
      #     m = MB::Sound::Meta::Value[notes: 'the doubled bass', tags: [:dark], source: { format: :acd, id: 3 }]
      #     m.notes                  # => ["the doubled bass"]
      #     m[:source][:id]          # => 3
      #     m.dig(:source, :format)  # => :acd
      #     m.with(author: 'mb')     # a new Value; a key given again is replaced whole
      #     m.note('half-time feel') # a new Value with one more note
      #     m.to_ruby                # => '{ notes: ["the doubled bass"], tags: [:dark], source: { format: :acd, id: 3 } }'
      #     MB::Sound::Meta::Value.parse(m.to_ruby) == m   # => true
      #     case m
      #     in { source: { format: :acd } } then ...      # pattern matching (#deconstruct_keys)
      #     end
      #
      # It acts as the frozen Hash it holds where that is what code expects
      # (#[], #dig, #key?, #each, #to_h, #to_hash, and == to a Hash with
      # the same entries), so `meta[:source][:id]` and `meta == { ... }`
      # read as before.
      #
      # Metadata describes; it never decides (design/notes/metadata.md):
      # nothing in mb-sound reads it to choose what plays, how a graph
      # builds, what a lookup finds, or what a loader constructs
      # (spec/lib/mb/sound/meta_guard_spec.rb keeps it so).
      class Value
        include Enumerable

        # The keys with readers, with what each holds.  Other keys are
        # welcome and kept as given (an importer's own facts); these mean
        # the same thing on every object, and #check_vocabulary keeps their
        # shapes (a note is text, a tag a word).
        VOCABULARY = {
          notes: 'commentary in words: a String or an Array of Strings (#note adds one)',
          tags: 'adjectives and roles: a Symbol or String, or an Array of them',
          author: 'who made it: a String or Symbol',
          license: 'how it may be used: a String or Symbol (e.g. "CC0-1.0")',
          links: 'where to read more: a String (a URL or path) or an Array of them',
          source: 'where it came from (a Hash; Meta::SOURCE_KEYS)',
          pack: 'the collection it belongs to: a String or Symbol',
        }.freeze

        # (classes each vocabulary key takes, alone or in an Array)
        SHAPES = {
          notes: [String],
          tags: [Symbol, String],
          author: [String, Symbol],
          license: [String, Symbol],
          links: [String],
          pack: [String, Symbol],
        }.freeze

        # (vocabulary keys that may be lists)
        LISTS = %i[notes tags links].freeze

        class << self
          # A Value of +values+ (a Hash, keywords, or both):
          # `Meta::Value[notes: 'x']`.
          def [](values = nil, **more)
            values = values.nil? ? more : Carrier.both(values, more)
            of(values)
          end

          # +x+ as a Value: a Value as is, nil and {} as EMPTY, a Hash
          # checked (Meta.merge's rules: Symbol keys at the top, plain values
          # below) and frozen.
          def of(x)
            case x
            when Value then x
            when nil then EMPTY
            when Hash then wrap(Meta.merge(nil, x))
            else raise ArgumentError, "metadata is a Hash of plain values (got #{Meta.describe(x)})"
            end
          end

          # The Value +text+ spells (a Hash literal as #to_ruby prints it),
          # read from the Prism tree and never run (Meta.parse).  Raises
          # ArgumentError for anything but a Hash of plain values.
          def parse(text)
            v = Meta.parse(text)
            raise ArgumentError, "metadata text holds a Hash (got #{Meta.describe(v)})" unless v.is_a?(Hash)
            of(v)
          end
        end

        # Checks +values+ (a Hash) and holds a deeply frozen copy (see
        # Value.of, which callers use).
        def initialize(values = Meta::EMPTY_HASH)
          @h = Meta.merge(nil, values)
          Value.check_vocabulary(@h)
          freeze
        end

        # (a Value holding +h+, a Hash Meta.merge checked and froze; values
        # already frozen stay the same objects)
        def self.wrap(h)
          return EMPTY if h.empty?
          v = allocate
          v.instance_variable_set(:@h, check_vocabulary(h))
          v.freeze
        end

        # Raises ArgumentError when a vocabulary key of +h+ has the wrong
        # shape (`notes: 3`).  Returns +h+.
        def self.check_vocabulary(h)
          SHAPES.each do |k, classes|
            next unless h.key?(k)
            v = h[k]
            items = LISTS.include?(k) && v.is_a?(Array) ? v : [v]
            next if items.all? { |i| classes.any? { |c| i.instance_of?(c) } }
            raise ArgumentError, "meta[#{k.inspect}] is #{VOCABULARY[k]} (got #{Meta.describe(v)})"
          end
          if h.key?(:source) && !h[:source].is_a?(Hash)
            raise ArgumentError, "meta[:source] is #{VOCABULARY[:source]} (got #{Meta.describe(h[:source])})"
          end
          h
        end

        ### Vocabulary

        # Commentary in words (an Array of Strings, empty when none).
        def notes = list(:notes)

        # Adjectives and roles (an Array of Symbols or Strings).
        def tags = list(:tags)

        # Where to read more (an Array of Strings).
        def links = list(:links)

        # Who made it, or nil.
        def author = @h[:author]

        # How it may be used, or nil.
        def license = @h[:license]

        # Where it came from (a frozen Hash; Meta::SOURCE_KEYS), or nil.
        def source = @h[:source]

        # The collection (preset pack) it belongs to, or nil.
        def pack = @h[:pack]

        ### New values

        # A Value with +values+' top-level keys merged in, each replacing
        # its old value whole (Meta.merge: what an importer wrote is never
        # half-updated).  Also available as #with, like Data#with.
        def merge(values = nil, **more)
          values = values.nil? ? more : Carrier.both(values.is_a?(Value) ? values.to_h : values, more)
          return self if values.empty?
          Value.wrap(Meta.merge(@h, values))
        end
        alias with merge

        # A Value with one more note per argument (Strings) at the end of
        # #notes.
        def note(*texts)
          texts.each do |t|
            raise ArgumentError, "a note is a String of commentary (got #{Meta.describe(t)})" unless t.is_a?(String)
          end
          return self if texts.empty?
          merge(notes: notes + texts)
        end

        # A Value without the given top-level keys.  Also available as
        # #except, like Hash#except.
        def without(*keys)
          kept = @h.except(*keys)
          kept.length == @h.length ? self : Value.wrap(kept.freeze)
        end
        alias except without

        # A Value with only the given top-level keys (Hash#slice).
        def slice(*keys)
          kept = @h.slice(*keys)
          kept.length == @h.length ? self : Value.wrap(kept.freeze)
        end

        ### Hash-like reading

        def [](key) = @h[key]
        def fetch(...) = @h.fetch(...)
        def dig(...) = @h.dig(...)
        def key?(key) = @h.key?(key)
        alias has_key? key?
        alias include? key?
        alias member? key?
        def keys = @h.keys
        def values = @h.values
        def size = @h.size
        alias length size
        def empty? = @h.empty?

        # Yields each top-level key and value.
        def each(&block)
          return enum_for(:each) { size } unless block
          @h.each(&block)
          self
        end
        alias each_pair each

        # The frozen Hash this Value holds (with a block, Hash#to_h's).
        def to_h(&block)
          block ? @h.to_h(&block) : @h
        end
        alias to_hash to_h

        # For pattern matching: `case meta in { source: { format: :acd } }`.
        def deconstruct_keys(_keys) = @h

        # True for a Value or Hash with the same entries.
        def ==(other)
          case other
          when Value then @h == other.to_h
          when Hash then @h == other
          else false
          end
        end

        def eql?(other) = other.is_a?(Value) && @h.eql?(other.to_h)
        def hash = [Value, @h].hash

        ### Printing

        # This Value as a Ruby Hash literal (through RubyValue, read back by
        # Value.parse): `{ notes: ["x"], source: { id: 3 } }`, `{}` when
        # empty.
        def to_ruby
          @h.empty? ? '{}' : RubyValue.to_ruby(@h)
        end

        # One line for listings (Meta.summary).
        def summary(kind: nil, file: nil) = Meta.summary(@h, kind: kind, file: file)

        def inspect
          @h.empty? ? '#<MB::Sound::Meta::Value {}>' : "#<MB::Sound::Meta::Value #{RubyValue.kwargs(@h)}>"
        end
        alias to_s inspect

        def pretty_print(q)
          q.text(inspect)
        end

        private

        def list(key)
          v = @h[key]
          case v
          when nil then Meta::EMPTY_LIST
          when Array then v
          else [v].freeze
          end
        end

        public

        # The Value without metadata.
        EMPTY = allocate.tap { |v| v.instance_variable_set(:@h, Meta::EMPTY_HASH) }.freeze
      end
    end
  end
end
