module MB
  module Sound
    module Library
      # The heads under MB::Sound::L (maintainer, 2026-10-26: "S1", a short
      # root then full words, each call narrowing the search; the word
      # heads are provisional): `L.inst`, `L.fx`, `L.kit`, `L.seq`,
      # `L.master`, `L.set`, `L.env`, `L.edit`, `L.mfx`, `L.analyze`,
      # `L.mod` (HEADS), and `L.all`.  Each is a Query; each word after it
      # narrows by a family (`L.fx.reverb`), a tag (`L.fx.bright`), or a
      # word of entry names (`L.inst.reese`: dnb_reese and jungle_reese),
      # and an entry's name gives the Entry (`L.fx.reverb.hall`, then
      # `.(sig)` to use it).  When a word leaves one entry, it is that
      # Entry.  The words are singleton methods of each Query, so Tab
      # lists them (UI::Completion completes `L.fx.` chains without
      # running them) and typos raise NoMethodError with did_you_mean.
      module Heads
        # A narrowed view of the index: +kind+ (or nil for every kind)
        # and the words chosen so far.  Reads the index when made.
        class Query
          include Enumerable

          # Query's own methods (words with these names are reached with
          # #[]).
          OWN = %i[entries names words find each first size length empty? inspect to_s path kind chosen word bench call pretty_print].freeze

          attr_reader :kind, :chosen, :path

          def initialize(kind, chosen = [], path:, pool: nil)
            @kind = kind
            @chosen = chosen.freeze
            @path = path
            @pool = (pool || Library.index.entries(kind: kind)).freeze
            Heads.define_words(self, words) unless @pool.empty?
          end

          # The entries left (one per family and name, the first in search
          # order).
          def entries = @pool
          def each(&block) = @pool.each(&block)
          def size = @pool.size
          alias length size
          def empty? = @pool.empty?

          # The entry names left.
          def names = @pool.map(&:name).uniq

          # Every word that narrows from here: names, families, tags, and
          # name words, sorted.
          def words
            w = @pool.flat_map { |e| [e.name, *e.words, *e.name_words] }
            (w.uniq - @chosen).select { |x| x.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) }.sort
          end

          # The result of narrowing by +word+: an Entry when +word+ names one
          # (or leaves one), else a Query; raises KeyError with suggestions
          # when nothing matches.
          def word(word)
            w = word.to_sym
            exact = @pool.select { |e| e.name == w }
            return exact.first if exact.length == 1
            narrowed = exact.length > 1 ? exact : @pool.select { |e| e.words.include?(w) }
            narrowed = @pool.select { |e| e.name_words.include?(w) } if narrowed.empty?
            if narrowed.empty?
              raise KeyError, "nothing under #{@path} is #{w.inspect}#{Library.suggest(w, words)}"
            end
            return narrowed.first if narrowed.length == 1 && narrowed.first.family != w && !narrowed.first.tags.include?(w)
            Query.new(@kind, @chosen + [w], path: "#{@path}.#{w}", pool: narrowed)
          end
          alias [] word

          # find within this query (see Index#find).
          def find(query, limit: 20)
            hits = Library.index.find(query, kind: @kind, limit: 10_000)
            keep = @pool.to_h { |e| [[e.family, e.name, e.shelf], true] }
            Index::Results.new(hits.query, hits.hits.select { |h| keep[[h.entry.family, h.entry.name, h.entry.shelf]] }.first(limit))
          end

          # Renders a Listening Bench set of the entries left (see
          # Library::Bench.run for the options): `L.fx.reverb.bench`,
          # `L.inst.dnb.bench(materials: [:template])`.
          def bench(**options)
            Library::Bench.run(self, **options)
          end

          # A table of what is left.
          def to_s
            return "Nothing under #{@path}" if @pool.empty?
            width = @pool.map { |e| e.name.length }.max
            lines = @pool.first(40).map { |e|
              "  #{e.name.to_s.ljust(width)}  #{e.family == :preset ? e.kind : e.family}#{" [#{e.tags.join(', ')}]" unless e.tags.empty?} #{e.shelf.name}"
            }
            lines << "  ... #{@pool.length - 40} more (.names)" if @pool.length > 40
            "#{@path}: #{@pool.length} entr#{@pool.length == 1 ? 'y' : 'ies'}\n#{lines.join("\n")}"
          end

          # Short, for messages and nesting ("#<L.inst.reese: 2 entries
          # (dnb_reese, jungle_reese)>"); the console prints the table
          # (#pretty_print: #to_s).
          def inspect
            "#<#{@path}: #{@pool.length} entr#{@pool.length == 1 ? 'y' : 'ies'}#{" (#{Heads.some_names(self)})" unless @pool.empty?}>"
          end

          def pretty_print(q) = q.text(to_s)

          # A Query is several entries: calling it says which to name.
          def call(*args, **kwargs, &block)
            Heads.call_word(self, @path, args, kwargs, block)
          end

          # A word that isn't one here (`L.inst.dnb_reeese`): what is, by
          # spelling (sd-ux-fixes-1, the review's #17: the NoMethodError
          # named only `#<...Heads::Query:0x...>`).
          def method_missing(name, *args, **kwargs, &block)
            return super unless name.match?(/\A[a-z_][a-z0-9_]*\z/) && !@pool.empty?
            left = @pool.length > 6 ? "#{@pool.length} entries: `#{@path}` lists them" : "#{@pool.length} entr#{@pool.length == 1 ? 'y' : 'ies'}: #{Heads.some_names(self)}"
            raise NoMethodError.new("nothing under #{@path} is #{name.inspect} (#{left})#{Library.suggest(name, words)}", name)
          end

          def respond_to_missing?(_name, _include_private = false) = false
        end

        # The root, MB::Sound::L: a head method per kind (HEADS), +all+,
        # and +find+.
        class Root
          HEADS.each do |head, kind|
            define_method(head) { Query.new(kind, path: "L.#{head}") }
          end

          # Every entry (no kind).
          def all = Query.new(nil, path: 'L.all')

          # Library find (see LibraryMethods#find).
          def find(query, **opts) = Library.index.find(query, **opts)

          def to_s
            "L: #{HEADS.map { |h, k| "L.#{h} (#{k})" }.join(', ')}, L.all, L.find"
          end

          def inspect = to_s
        end

        module_function

        # Defines the words of +query+ as its singleton methods.  Given
        # arguments, a word naming an entry calls it: `L.gen.techno_beat(seed:
        # 3)` is `L.gen.techno_beat.(seed: 3)`, `L.fx.hall(sig)` is
        # `L.fx.hall.(sig)` (lib-gen-1).
        def define_words(query, words)
          words.each do |w|
            next if Query::OWN.include?(w) || Query.method_defined?(w) || Object.method_defined?(w)
            query.define_singleton_method(w) { |*args, **kwargs, &block|
              found = word(w)
              next found if args.empty? && kwargs.empty? && block.nil?
              Heads.call_word(found, "#{path}.#{w}", args, kwargs, block)
            }
          end
        end

        # Calls +found+ (what a word gave) with arguments: an Entry builds;
        # a Query (several entries) raises with their paths.
        def call_word(found, path, args, kwargs, block)
          return found.call(*args, **kwargs, &block) if found.is_a?(Entry)
          raise ArgumentError, "#{path} is #{found.size} entries (#{some_names(found)}); " \
            "name one to call it (#{path}.#{found.first.name}(...))"
        end

        # Words for +query+ given where one entry goes (a track's or
        # design's instrument, play): which entries it is and how to name
        # one.  +what+ names the place ("track :bass").
        def several(query, what)
          return "#{what}: nothing under #{query.path}" if query.empty?
          "#{what}: #{query.path} is #{query.size} entries (#{some_names(query)}); name one (#{query.path}.#{query.first.name})"
        end

        # The first few entry names of +query+ ("dnb_reese, jungle_reese").
        def some_names(query)
          names = query.names
          "#{names.first(6).join(', ')}#{names.length > 6 ? ', ...' : ''}"
        end

        # Tab completions for +text+ (a console word like "L.fx.re" or
        # "MB::Sound::L.inst."), or nil when +text+ isn't a head chain:
        # walks the words without running anything else.
        def completions(text)
          m = text.to_s.match(/\A((?:MB::Sound::|::)?L)((?:\.[a-z_][a-z0-9_]*)*)\.([a-z_][a-z0-9_]*)?\z/)
          return nil unless m
          root = m[1]
          chain = m[2].split('.').reject(&:empty?).map(&:to_sym)
          prefix = m[3].to_s
          node = Root.new
          path = root
          chain.each do |w|
            node = if node.is_a?(Root)
                     return nil unless HEADS.key?(w) || w == :all
                     node.public_send(w)
                   elsif node.is_a?(Query)
                     node.word(w)
                   else
                     return nil
                   end
            path = "#{path}.#{w}"
          end
          words = case node
                  when Root then [*HEADS.keys, :all, :find]
                  when Query then node.words.reject { |w| Query::OWN.include?(w) } + %i[entries names find bench]
                  else %i[call to_ruby about tags params head_path audition auditions bench]
                  end
          words.map(&:to_s).select { |w| w.start_with?(prefix) }.sort.map { |w| "#{path}.#{w}" }
        rescue KeyError, StandardError
          nil
        end
      end
    end

    # The library's root head (see Library::Heads): L.fx.reverb.hall,
    # L.inst.dnb_reese, L.kit.tr909, L.seq, L.all.find('dark').
    L = Library::Heads::Root.new
  end
end
