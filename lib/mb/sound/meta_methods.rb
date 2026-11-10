module MB
  module Sound
    # Console commands for metadata (see MB::Sound::Meta): what the set and
    # its named pieces carry from the files they came from.
    module MetaMethods
      # (`meta :a3` with no values reads)
      READ = Object.new.freeze
      private_constant :READ

      # Reads or adds to the metadata of a named piece of the set (a
      # track, bus, mute group, knob, or rack), or of the set itself when
      # no name is given: plain facts that travel with the piece and
      # change nothing about its sound, such as where an importer found
      # it (see Meta; `help :meta`).
      #
      #     meta :a3, source: { format: :acd, kind: :track, at: 0x12340, bytes: 5678, fields: { color: 3 } }
      #     meta :a3, notes: 'the doubled bass'     # merges: :source stays
      #     meta source: { format: :acd, file: 'project.acd', bytes: 1_234_567 }   # the set itself
      #     meta :a3                                 # => { source: { ... }, notes: "..." }
      #     meta                                     # => the set's own
      #     meta :a3, nil                            # forgets :a3's
      #
      # Values merge by top-level key (a key given again is replaced
      # whole) and must be plain Ruby: numbers, Strings, Symbols, true,
      # false, nil, Arrays, and Hashes of those.  The name needs no piece
      # yet, so a song file can list its metadata first or last, and
      # metadata stays with a name through `untrack`, swaps, scenes, and
      # undo.  Set documents save it (`save :gig, set`); `metas` lists it.
      # Returns the piece's metadata, a frozen Hash ({} when it has none).
      # Also available as #metadata.
      def meta(name = nil, values = READ, **more)
        store = Session.current.metadata
        if name.is_a?(Hash) && READ.equal?(values)
          values = name
          name = nil
        end
        if values.nil? && more.empty?
          store.clear(name)
          return Meta::EMPTY
        end
        values = READ.equal?(values) ? more : Meta::Carrier.both(values, more)
        return store[name] if values.empty?
        store.merge(name, values)
      end
      alias metadata meta

      # Lists the metadata the set carries, one line per name: where it
      # came from, what it was there, its place and size in the file, and
      # how much came along ("from project.acd, track at 0x12340, 5.5 KB,
      # 2 fields carried"); the set's own is under nil.  `meta :name`
      # gives one piece's in full.  Returns a Hash from name to line.
      def metas
        session = Session.current
        store = session.metadata
        own = store[nil]
        file = own[:source].is_a?(Hash) ? own[:source][:file] : nil
        out = {}
        out[nil] = Meta.summary(own, kind: :set) unless own.empty?
        store.to_h.each do |name, m|
          out[name] = Meta.summary(m, kind: session.names.kind(name) || :'not defined', file: file.is_a?(String) ? file : nil)
        end
        out
      end
    end
  end
end
