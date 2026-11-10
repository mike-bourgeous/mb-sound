module MB
  module Sound
    # Metadata: plain facts carried on mb-sound objects without any effect
    # on their sound (source-meta-1, 2026-11-10; the maintainer: "add
    # metadata to every mb-sound type that maps from a converter so that
    # understood but ignored fields get consumed").  Importers (the ACID
    # .acd converter, trackers, MIDI files, SoundFonts) read more from a
    # foreign file than mb-sound turns into sound: a track's colour and
    # height, a bus's own name, a plug-in's preset name, where the object
    # sat in the file.  They carry those here instead of dropping them.
    #
    # Who carries metadata:
    # - a Session's named pieces (tracks, buses, groups, knobs, racks) and
    #   the set itself: `meta :bass, source: { ... }` (MetaMethods, kept in
    #   a Meta::Store, saved in set documents);
    # - graph nodes and bundles: `node.with_meta(source: { ... })`
    #   (Meta::Carrier, printed by `to_ruby` and saved in graph documents);
    # - Samples: `sample.with_meta(source: { ... })`, and `sample.meta`
    #   (a Sample read from a WAV file brings the file's own `:source`).
    #
    # A piece's metadata is one frozen Hash with Symbol keys at the top.
    # Values are plain Ruby (see .check): Integers, Floats, Rationals,
    # Strings, Symbols, true, false, nil, and Arrays and Hashes of those
    # (Hash keys: Symbols, Strings, or Integers), so every value prints
    # through RubyValue and reloads without eval.
    #
    # By convention provenance goes under +:source+ (SOURCE_KEYS; the
    # library reads these only to print summaries, and checks nothing
    # inside but the value rule):
    #
    #     meta :a3, source: { format: :acd, kind: :track, at: 0x12340, bytes: 5678,
    #                         name: "the track's own name", fields: { color: 3, height: 80 } }
    module Meta
      # What a piece without metadata has.
      EMPTY = {}.freeze

      # The keys importers use inside +:source+, in the order summaries
      # and documents read best, with what each holds.  Other keys are
      # welcome (a format's own facts); these mean the same thing in every
      # importer.
      SOURCE_KEYS = {
        format: 'the foreign format (a Symbol: :acd, :wav, :mod, :mid, :sf2, :sfz)',
        file: 'the file the object came from (a name or path, as the importer was given it)',
        version: 'the format version the file says it is (a String or number)',
        kind: 'what the object was in the file (a Symbol: :track, :bus, :clip, :plugin, :envelope, ...)',
        id: 'the object\'s own ID or index in the file',
        name: 'the object\'s own name in the file, when mb-sound names it otherwise',
        at: 'the byte offset of the object in the file',
        bytes: 'the object\'s size in bytes in the file (for the file itself: its size)',
        records: 'how many records, events, or entries the object holds in the file',
        unread: 'what was not understood: bytes (an Integer) or the fraction of the object (a Float, 0..1)',
        fields: 'understood-but-unused values by name (a Hash): what mb-sound has no place for yet',
      }.freeze

      # How deep values may nest (a list holding itself would otherwise
      # never end).
      MAX_DEPTH = 32

      # Hash key classes below the top level.
      KEYS = [Symbol, String, Integer].freeze

      module_function

      # Checks that +value+ is plain Ruby as metadata allows (see the
      # module description), raising an ArgumentError that names the key
      # path of the first value that isn't (`meta[:source][:fields][2]`).
      # Returns +value+.
      def check(value, path = [])
        raise ArgumentError, "#{where(path)} nests deeper than #{MAX_DEPTH} levels (a list holding itself?)" if path.length > MAX_DEPTH

        case value
        when nil, true, false, Symbol, String, Integer, Rational
          value
        when Float
          # (a Decibels or another Float-like value object is not a Float here)
          value
        when Array
          value.each_with_index { |v, i| check(v, path + [i]) }
          value
        when Hash
          value.each do |k, v|
            unless KEYS.any? { |c| k.instance_of?(c) }
              raise ArgumentError, "#{where(path)} has the key #{k.inspect} (#{k.class}); metadata keys are Symbols, Strings, or Integers"
            end
            check(v, path + [k])
          end
          value
        else
          raise ArgumentError, "#{where(path)} is #{describe(value)}; metadata values are plain Ruby: numbers (Integer, Float, Rational), " \
                               'Strings, Symbols, true, false, nil, and Arrays and Hashes of those'
        end
      end

      # A deeply frozen copy of +value+ (checked values only): the caller's
      # Strings, Arrays, and Hashes stay theirs.
      def frozen(value)
        case value
        when String then value.frozen? ? value : value.dup.freeze
        when Array then value.map { |v| frozen(v) }.freeze
        when Hash then value.to_h { |k, v| [frozen(k), frozen(v)] }.freeze
        else value
        end
      end

      # +old+ (a frozen metadata Hash or nil) with +values+' top-level keys
      # merged in, checked and frozen: a key given again replaces its
      # value whole (`meta :a3, notes: 'x'` keeps `:source`; a second
      # `source:` replaces the first).  Top-level keys are Symbols.
      def merge(old, values)
        raise ArgumentError, "metadata is a Hash of plain values (got #{describe(values)})" unless values.is_a?(Hash)
        values.each_key do |k|
          raise ArgumentError, "meta[#{k.inspect}]: top-level metadata keys are Symbols, like source: or notes: (got #{describe(k)})" unless k.instance_of?(Symbol)
        end
        check(values)
        return old || EMPTY if values.empty?
        (old || EMPTY).merge(frozen(values)).freeze
      end

      # One line about +meta+ for listings: "from project.acd, track at
      # 0x12340, 5.5 KB, 2 fields carried" (the +:source+ convention's
      # keys, then the names of any other top-level keys); "(none)" when
      # empty.  +kind+ (what the piece is in the Session, e.g. :track) and
      # +file+ (the set's source file) stand in when the piece's own
      # source doesn't say.
      def summary(meta, kind: nil, file: nil)
        return '(none)' if meta.nil? || meta.empty?
        parts = []
        src = meta[:source]
        if src.is_a?(Hash)
          own = src[:file]
          name = own.is_a?(String) && !own.empty? ? own : file
          name = name.split(%r{[/\\]}).last if name.is_a?(String)
          format = [src[:format], src[:version]].compact.join(' ')
          from = name ? (src[:version] ? "#{name} (#{format})" : name) : format
          parts << "from #{from}" unless from.to_s.empty?
          what = [src[:kind] || kind, (src[:id] && "##{src[:id]}"), (src[:name] && src[:name].to_s.inspect)].compact.map(&:to_s)
          what << "at 0x#{src[:at].to_s(16)}" if src[:at].is_a?(Integer)
          parts << what.join(' ') unless what.empty?
          parts << bytes_text(src[:bytes]) if src[:bytes].is_a?(Integer)
          parts << "#{src[:records]} records" if src[:records].is_a?(Integer)
          n = src[:fields].respond_to?(:size) ? src[:fields].size : 0
          parts << "#{n} field#{'s' unless n == 1} carried" if n > 0
          case (u = src[:unread])
          when Integer then parts << "#{bytes_text(u)} unread" if u > 0
          when Float
            pct = (u * 100).round(1)
            parts << "#{pct == pct.to_i ? pct.to_i : pct}% unread"
          end
          extra = src.keys - SOURCE_KEYS.keys
          parts << (extra.length <= 3 ? "+ #{extra.join(', ')}" : "+ #{extra.length} more") unless extra.empty?
        elsif !src.nil?
          parts << "source #{src.inspect}"
        elsif kind
          parts << kind.to_s
        end
        others = meta.keys - [:source]
        parts << "#{src.nil? ? '' : 'also '}#{others.join(', ')}" unless others.empty?
        parts.join(', ')
      end

      # A byte count in words: "812 bytes", "5.5 KB", "1.2 MB".
      def bytes_text(n)
        return "#{n} byte#{'s' unless n == 1}" if n < 1024
        v = n.to_f
        unit = nil
        %w[KB MB GB TB].each do |u|
          v /= 1024
          unit = u
          break if v < 1024
        end
        "#{v >= 100 ? v.round : v.round(1)} #{unit}"
      end

      # The `meta` statement that gives +name+ (nil for the set itself)
      # +meta+, as lines of Ruby for set documents and `ruby set`: `meta
      # :a3, source: { ... }` on one line when it fits +width+, else
      # `meta(:a3,` with one top-level key per line, long Hashes and
      # Arrays opened with their entries filled to the width.  Values
      # print through RubyValue.
      def statement(name, meta, width: 120)
        one = "meta #{[name&.inspect, RubyValue.kwargs(meta)].compact.join(', ')}"
        return [one] if one.length <= width
        lines = [name.nil? ? 'meta(' : "meta(#{name.inspect},"]
        entries = meta.to_a
        entries.each_with_index do |(k, v), i|
          lines.concat(entry_lines("#{RubyValue.key(k)} ", v, width, 2, i == entries.length - 1 ? ')' : ','))
        end
        lines
      end

      # (lines for one `key: value` or list element with +tail+ after it;
      # a Hash or Array that doesn't fit is opened, see .filled)
      def entry_lines(lead, value, width, indent, tail)
        pad = ' ' * indent
        one = "#{pad}#{lead}#{RubyValue.to_ruby(value)}#{tail}"
        return [one] if one.length <= width || !(value.is_a?(Hash) || value.is_a?(Array)) || value.empty?
        open, close = value.is_a?(Hash) ? %w[{ }] : %w([ ])
        ["#{pad}#{lead}#{open}", *filled(value, width, indent + 2), "#{pad}#{close}#{tail}"]
      end

      # (the entries of an opened Hash or Array: as many per line as fit,
      # an entry too long for a line opened on lines of its own)
      def filled(value, width, indent)
        pad = ' ' * indent
        lines = []
        line = nil
        flush = -> { lines << "#{pad}#{line}" if line; line = nil }
        entries = value.is_a?(Hash) ? value.map { |k, v| [hash_key(k), v] } : value.map { |v| ['', v] }
        entries.each do |lead, v|
          text = "#{lead}#{RubyValue.to_ruby(v)},"
          if indent + text.length > width && (v.is_a?(Hash) || v.is_a?(Array)) && !v.empty?
            flush.call
            lines.concat(entry_lines(lead, v, width, indent, ','))
          elsif line && indent + line.length + 1 + text.length <= width
            line = "#{line} #{text}"
          else
            flush.call
            line = text
          end
        end
        flush.call
        lines
      end

      # (`name: ` for a Symbol key, `"k" => ` and `3 => ` for others)
      def hash_key(k)
        k.is_a?(Symbol) ? "#{RubyValue.key(k)} " : "#{RubyValue.to_ruby(k)} => "
      end

      # The value +text+ spells, for metadata kept as text (a Sample's
      # `:source` in a saved file's tag): the plain values .check allows,
      # as RubyValue prints them, read from the Prism tree, never run.
      # Raises ArgumentError for anything else (a call, a constant, an
      # interpolated String).
      def parse(text)
        require 'prism'
        result = Prism.parse(text.to_s)
        body = result.value.statements.body
        raise ArgumentError, "metadata text doesn't parse as Ruby: #{result.errors.first.message}" unless result.errors.empty?
        raise ArgumentError, "metadata text holds one value (got #{body.length} statements)" unless body.length == 1
        literal(body[0])
      end

      # (the plain value of Prism node +n+)
      def literal(n)
        case n
        when Prism::NilNode then nil
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode then n.value
        when Prism::SymbolNode then n.unescaped.to_sym
        when Prism::StringNode then n.unescaped.dup.force_encoding(Encoding::UTF_8).freeze
        when Prism::ArrayNode then n.elements.map { |e| literal(e) }
        when Prism::ParenthesesNode
          raise ArgumentError, 'metadata text holds plain values only' unless n.body.is_a?(Prism::StatementsNode) && n.body.body.length == 1
          literal(n.body.body[0])
        when Prism::HashNode, Prism::KeywordHashNode
          n.elements.to_h do |e|
            raise ArgumentError, 'metadata text holds plain values only (no ** in a Hash)' unless e.is_a?(Prism::AssocNode)
            [literal(e.key), literal(e.value)]
          end
        when Prism::ConstantPathNode
          # (Float::INFINITY and Float::NAN, as RubyValue prints them)
          case n.slice
          when 'Float::INFINITY' then Float::INFINITY
          when 'Float::NAN' then Float::NAN
          else raise ArgumentError, "metadata text holds plain values only (got the constant #{n.slice})"
          end
        when Prism::CallNode
          # (`3/4r`, `-3/4r`: a Rational as RubyValue prints it; `-Float::INFINITY`)
          if n.name == :/ && n.receiver.is_a?(Prism::IntegerNode) && n.arguments&.arguments&.length == 1 && n.arguments.arguments[0].is_a?(Prism::RationalNode) && n.block.nil?
            n.receiver.value / n.arguments.arguments[0].value
          elsif n.name == :-@ && n.receiver && n.arguments.nil? && n.block.nil? && (v = literal(n.receiver)).is_a?(Numeric)
            -v
          else
            raise ArgumentError, "metadata text holds plain values only (got the call #{n.slice[0, 40]})"
          end
        else
          raise ArgumentError, "metadata text holds plain values only (got #{n.slice[0, 40]})"
        end
      end

      # (`meta[:source][:fields][2]` for a key path)
      def where(path)
        "meta#{path.map { |k| "[#{k.inspect}]" }.join}"
      end

      # ("a Proc", "a MB::Sound::Tone")
      def describe(value)
        name = value.class.name || value.class.inspect
        "#{name.match?(/\A[AEIOU]/) ? 'an' : 'a'} #{name} (#{value.inspect.then { |s| s.length > 60 ? "#{s[0, 57]}..." : s }})"
      end

      # The metadata of a Session: the set's own and each named piece's
      # (`meta :bass, source: { ... }`; see MetaMethods), by name.
      #
      # A name needs no piece: a song file may list its metadata before or
      # after its tracks and buses, and metadata stays with the name when
      # its piece is removed (`untrack`), as the name's knobs, level, and
      # routes do, so a piece defined again under the name has it.
      #
      # Nothing here is read while rendering, and nothing here changes
      # what plays, so metadata is not a Session change: it has its own
      # lock, lands at once, and is not an undo step.
      class Store
        def initialize
          @set = EMPTY
          @pieces = {}
          @mutex = Mutex.new
        end

        # The metadata of piece +name+ (a Symbol), or the set's own for
        # nil: a frozen Hash, empty when there is none.
        def [](name = nil)
          Store.check_name(name)
          @mutex.synchronize { name.nil? ? @set : (@pieces[name] || EMPTY) }
        end

        # Merges +values+' top-level keys into what +name+ has (see
        # Meta.merge).  Returns the piece's metadata.
        def merge(name, values)
          Store.check_name(name)
          @mutex.synchronize do
            merged = Meta.merge(name.nil? ? @set : @pieces[name], values)
            if name.nil?
              @set = merged
            elsif merged.empty?
              @pieces.delete(name)
            else
              @pieces[name] = merged
            end
            merged
          end
        end

        # Forgets the metadata of +name+ (the set's own for nil).  Returns
        # what it had.
        def clear(name = nil)
          Store.check_name(name)
          @mutex.synchronize do
            if name.nil?
              old = @set
              @set = EMPTY
              old
            else
              @pieces.delete(name) || EMPTY
            end
          end
        end

        # The names with metadata, in the order they first got some.
        def names
          @mutex.synchronize { @pieces.keys }
        end

        # Each named piece's metadata by name (a copy; the set's own is
        # #[] with no name).
        def to_h
          @mutex.synchronize { @pieces.dup }
        end

        # True when neither the set nor any name has metadata.
        def empty?
          @mutex.synchronize { @set.empty? && @pieces.empty? }
        end

        # How many names have metadata (the set's own not counted).
        def size
          @mutex.synchronize { @pieces.size }
        end

        def self.check_name(name)
          return if name.nil? || name.is_a?(Symbol)
          raise ArgumentError, "meta takes a piece's name as a Symbol (meta :bass, source: { ... }), or none for the set itself (got #{Meta.describe(name)})"
        end
      end

      # Metadata on an object itself, for objects without a Session name:
      # graph nodes and bundles (GraphNode includes this).  Importers that
      # build objects rather than text (trackers, MIDI files) tag what they
      # build:
      #
      #     voice = sampler(sample).with_meta(source: { format: :xm, kind: :instrument, id: 3, at: 0x1f40, bytes: 263 })
      #     voice.meta[:source][:id]   # => 3
      #
      # Carried metadata is not sound: it changes no sample, no plan, and
      # no allocation while rendering.  `to_ruby` prints it (as
      # `.with_meta(...)`, like `.named`), so recipes and graph documents
      # keep it.
      module Carrier
        # Merges +values+ (a Hash, or keywords) into this object's metadata
        # by top-level key (see Meta.merge; `:source` by convention holds
        # where it came from, Meta::SOURCE_KEYS) and returns the object,
        # so it chains like #named.  `with_meta(nil)` forgets it all.
        def with_meta(values = Carrier::NONE, **more)
          if values.nil? && more.empty?
            @carried_meta = nil
            return self
          end
          values = Carrier::NONE.equal?(values) ? more : Carrier.both(values, more)
          @carried_meta = Meta.merge(@carried_meta, values)
          @carried_meta = nil if @carried_meta.empty?
          self
        end

        # This object's metadata (see #with_meta): a frozen Hash, empty
        # when it carries none.
        def meta
          @carried_meta || EMPTY
        end

        # (no positional argument given)
        NONE = Object.new.freeze

        # (a positional Hash and keywords as one Hash)
        def self.both(values, more)
          raise ArgumentError, "metadata is a Hash of plain values (got #{Meta.describe(values)})" unless values.is_a?(Hash)
          more.empty? ? values : values.merge(more)
        end
      end
    end
  end
end
