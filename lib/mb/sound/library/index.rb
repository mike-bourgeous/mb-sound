require 'monitor'
require 'set'

module MB
  module Sound
    module Library
      # Two shipped entries with one name in one family, or a word that is
      # both a tag and an entry name under one head (see Index#register).
      class Collision < ArgumentError; end

      # The one index of library entries (see Entry): the class presets
      # (Presettable), entries registered in code (drum machines, genre
      # patches), and the shelves' library files and graph documents,
      # searched in SHELF_ORDER.
      #
      # Collisions (maintainer, 2026-10-24): on shipped shelves (mb-sound's
      # built-ins) a second entry of the same name and family, or a name
      # that is also a tag or family word under the same head, raises
      # Collision when registered in code and is listed in #problems for
      # shipped files (a guard spec checks it is empty); on the other
      # shelves the first in search order wins with a warning (once), and
      # #conflicts and #find show the shadowed entries.  A pinned copy
      # (see Library.collect) equal to the entry it shadows doesn't warn.
      #
      # Library files are read when an entry is first looked up, and again
      # after #reload! or when the shelves change (the working directory's
      # project, $MB_SOUND_PRESETS, the user shelf); saves, collect, and
      # promote reload.  Graph documents are listed from file names for
      # `preset :x` and read (headers only, cached by modification time)
      # for #find and the heads.
      class Index
        # A find result: +entry+, +score+, +matched+ (terms matched), and
        # +why+ (what each term matched: "name", "tag dark", ...).
        Hit = Data.define(:entry, :score, :matched, :why)

        # The ranked result of #find: +query+ (the terms) and +hits+.
        # Prints as a short table (head path, kind, shelf, why).
        class Results
          include Enumerable

          attr_reader :query, :hits

          def initialize(query, hits, conflicts = {})
            @query = query.freeze
            @hits = hits.freeze
            @conflicts = conflicts
            freeze
          end

          def each(&block) = entries.each(&block)
          def entries = @hits.map(&:entry)
          def [](i) = entries[i]
          def size = @hits.size
          alias length size
          def empty? = @hits.empty?

          # The table: one line per hit, best first.
          def to_s
            return "Nothing in the library matches #{@query.join(' ')}" if @hits.empty?
            width = @hits.map { |h| h.entry.head_path.length }.max
            @hits.map { |h|
              e = h.entry
              shadow = @conflicts[[e.family, e.name]]
              note = shadow ? "  (shadows #{shadow.map { |s| s.shelf.name }.join(', ')})" : ''
              about = e.about ? "  #{e.about[0, 60]}#{'...' if e.about.length > 60}" : ''
              "#{e.head_path.ljust(width)}  #{e.kind.to_s.ljust(10)} #{e.shelf.name.to_s.ljust(7)} #{h.why.join(', ')}#{note}#{about}"
            }.join("\n")
          end

          def inspect = to_s
        end

        def initialize
          @lock = Monitor.new
          @families = {}
          @aliases = Hash.new { |h, k| h[k] = {} }
          @code = {} # [family, name] => Entry (class presets and code registrations)
          @files_key = nil
          @files = [] # library-file entries of the file shelves, in search order
          @pins = [] # pin lines of the file shelves (Library::Pins)
          @problems = []
          @warned = Set.new
          @documents = {} # path => [mtime, size, Entry]
          @uses = {}.compare_by_identity # (Data#hash would hash every setting per lookup)
          @loading = false
        end

        ### Families and registration (code)

        # Declares a family (see Family); returns it.
        def define_family(name, kind:, about: nil, owner: nil, apply: nil, code: nil, document: nil)
          @lock.synchronize do
            f = Family.new(name: name, kind: kind, about: about, owner: owner, apply: apply, code: code, document: document)
            old = @families[name]
            raise Collision, "family #{name.inspect} is declared twice (#{old.owner.inspect} and #{owner.inspect})" if old && old.owner && owner && !old.owner.equal?(owner)
            @families[name] = f
          end
        end

        # The families by name.
        def families
          @lock.synchronize { @families.dup }
        end

        # Registers an entry made in code (a class preset, a drum machine):
        # a shipped entry, so a second entry of its family and name, or a
        # name or tag clashing with another entry's under the same head,
        # raises Collision with a rename suggestion.  Returns the entry.
        def register(entry)
          @lock.synchronize do
            key = [entry.family, entry.name]
            if (old = @code[key])
              raise Collision, "#{entry.label} is defined twice (#{old.location} and #{entry.location}); rename one"
            end
            clash = word_clash(entry, @code.values)
            raise Collision, clash if clash
            @code[key] = entry
          end
          entry
        end

        # Makes +alias_name+ another name for +name+ in +family+ (lookups
        # only; listings show the name).
        def add_alias(family, alias_name, name)
          @lock.synchronize { @aliases[family][alias_name.to_sym] = name.to_sym }
        end

        # The aliases of +family+ ({ alias => name }).
        def aliases(family)
          @lock.synchronize { @aliases[family].dup }
        end

        ### Lookups

        # The entry named +name+ (a Symbol or String; an alias works when
        # no entry has that name) in +family+, the first in search order,
        # or nil.  A found entry counts as used (see #uses) unless
        # +note:+ is false.
        def lookup(family, name, note: true)
          return nil unless name.is_a?(Symbol) || name.is_a?(String)
          name = name.to_sym
          found = candidates(family, name).first
          found ||= (target = aliases(family)[name]) && candidates(family, target).first
          note_use(found) if found && note
          found
        end

        # The entry named +name+ in +family+ (see #lookup), raising
        # ArgumentError "Unknown +label+ :name (names...)" with did-you-mean
        # suggestions when there is none.
        def fetch(family, name, label: "#{family} preset")
          found = lookup(family, name)
          return found if found
          names = names(family)
          raise ArgumentError, "Unknown #{label} #{name.inspect} (#{names.map(&:inspect).join(', ')})#{Library.suggest(name, names + aliases(family).keys)}"
        end

        # Every entry named +name+ in +family+, in search order (the first
        # is the one used; the rest are shadowed).  Graph documents aren't
        # included (see #preset_target).
        def candidates(family, name)
          name = name.to_sym
          all = file_entries
          code = @code[[family, name]] # (registrations happen while loading; reads need no lock)
          return code ? [code] : [] if all.empty? && family != :preset # (the common case: built-ins only)
          files = all.select { |e| e.family == family && e.name == name }
          session = family == :preset ? session_entries.select { |e| e.name == name } : []
          (session + files + [code].compact).sort_by.with_index { |e, i| [e.shelf.rank, i] }
        end

        # The winning entries (one per family and name), optionally only of
        # +kind+ or +family+; with +documents:+ (the default) the shelves'
        # graph documents too.  +shadowed: true+ includes the shadowed
        # entries.  Listings across families (no +family:+, documents
        # included) leave out the shipped presets a shipped document
        # stands for (Family#document: the SQ-80 patches, listed as their
        # sq80_ documents).
        def entries(kind: nil, family: nil, documents: true, shadowed: false)
          all = all_entries(documents: documents)
          all = all.select { |e| e.kind == kind } if kind
          all = all.select { |e| e.family == family } if family
          all = without_listed_documents(all) if documents && !family
          return all if shadowed
          seen = {}
          all.each { |e| seen[[e.family, e.name]] ||= e }
          seen.values
        end

        # Every entry in search order, shadowed ones included.
        def all_entries(documents: true)
          code = @lock.synchronize { @code.values }
          list = session_entries + file_entries + (documents ? document_entries : []) + code
          list.each_with_index.sort_by { |e, i| [e.shelf.rank, i] }.map(&:first)
        end

        # Names in +family+ (winning entries).
        def names(family)
          entries(family: family, documents: family == :preset).map(&:name)
        end

        # Names that shadow others: { [family, name] => [shadowed entries] }.
        def conflicts
          entries(shadowed: true).group_by { |e| [e.family, e.name] }.select { |_, l| l.length > 1 }.transform_values { |l| l.drop(1) }
        end

        # The `pin` lines of the file shelves (Library::Pins::Pin; collect
        # writes them into a song's presets/pins.rb).
        def pins
          file_entries
          @pins
        end

        # Problems found in shipped files and unreadable files: [message].
        def problems
          file_entries
          document_entries
          @lock.synchronize { @problems.dup }
        end

        # What `preset :x` loads for +name+, the first in search order:
        # [:document, path] for a graph document (plain or a bundle's), or
        # [:entry, entry] for a library-file instrument or chain; nil if
        # neither exists.  The Session's racks aren't searched (`preset`
        # reads shelves).
        def preset_target(name)
          name = name.to_sym
          files = file_entries.select { |e| e.family == :preset && e.name == name }
          Library.shelves.each do |shelf|
            next unless shelf.dir
            path = Library.document_path(shelf.dir, name)
            return [:document, path] if path
            hit = files.find { |e| e.shelf == shelf }
            return [:entry, hit] if hit
          end
          nil
        end

        ### find

        # Searches the library: +query+ is words in a String ("dark bass"),
        # Symbols, or an Array of them; each word may match an entry's
        # name (exactly, a word of it, or a prefix), a tag, its family or
        # kind, or its description.  Hits matching every word come first
        # (if any entry matches every word, only those are listed), then by
        # score (name > tag > family/kind > about), then by shelf order.
        # +kind:+/+family:+ narrow; +limit:+ caps the list.  Returns
        # Results (prints as a table showing why each matched and what it
        # shadows).
        def find(query, kind: nil, family: nil, limit: 20, documents: true)
          terms = Library.terms(query)
          pool = entries(kind: kind, family: family, documents: documents)
          hits = pool.filter_map { |e| score(e, terms) }
          best = hits.map(&:matched).max
          hits = hits.select { |h| h.matched == best } if best && best == terms.length && !terms.empty?
          hits = hits.sort_by { |h| [-h.matched, -h.score, h.entry.shelf.rank, h.entry.name.to_s] }
          Results.new(terms, hits.first(limit), conflicts)
        end

        ### Uses (for collect)

        # Records that +entry+ was used (looked up by its family or
        # loaded).
        def note_use(entry)
          @lock.synchronize { @uses[entry] = true } if entry
          entry
        end

        # Records the graph document at +path+ as used (when it is on a
        # shelf).
        def note_path(path)
          full = File.expand_path(path)
          shelf = Library.shelves.find { |sh| sh.dir && full.start_with?("#{sh.dir}/") }
          e = shelf && document_entry(full, shelf)
          note_use(e)
        rescue StandardError
          nil
        end

        # The entries used since the process started (or #clear_uses), in
        # the order first used.
        def uses
          @lock.synchronize { @uses.keys }
        end

        def clear_uses
          @lock.synchronize { @uses.clear }
        end

        ### Loading

        # Reads the library files and document headers again on next use.
        def reload!
          @lock.synchronize do
            @files_key = nil
            @files = []
            @pins = []
            @documents.clear
            @problems.clear
          end
          self
        end

        # The library-file entries of the file shelves (read when the
        # shelves change, or after #reload!).
        def file_entries
          return [] unless defined?(MB::Sound::GraphIO::Loader) # (still loading mb-sound)
          shelves = Library.shelves
          return @files if @files_key.equal?(shelves) # (the shelves list is remembered: the same object while nothing changed)
          key = shelves
          @lock.synchronize do
            return @files if @files_key.equal?(key) || @loading
            @loading = true
            begin
              @problems.reject! { |p| p.start_with?('file ') }
              list = []
              pins = []
              shelves.each do |shelf|
                next unless shelf.dir && File.directory?(shelf.dir)
                Library.library_files(shelf.dir).each do |path|
                  list.concat(FileLoader.load(path, shelf: shelf, pins: shelf.shipped? ? nil : pins))
                rescue StandardError, ScriptError => e
                  problem(shelf, "file #{path}: #{e.message}")
                end
              end
              @files = list.freeze
              @pins = pins.freeze
              @files_key = key
              check_files(list)
              check_pins(pins)
            ensure
              @loading = false
            end
            @files
          end
        end

        # Entries for the shelves' graph documents (headers read once per
        # file version).
        def document_entries
          return [] unless defined?(MB::Sound::GraphIO::Loader)
          list = []
          Library.shelves.each do |shelf|
            next unless shelf.dir && File.directory?(shelf.dir)
            Library.document_paths(shelf.dir).each do |path|
              e = document_entry(path, shelf)
              list << e if e
            end
          end
          list
        end

        private

        # +list+ without the shipped class presets whose family names a
        # shipped graph document in +list+ standing for them.
        def without_listed_documents(list)
          stand_ins = @families.values.select(&:document)
          return list if stand_ins.empty?
          shipped = nil
          list.reject { |e|
            next false unless e.shelf.shipped? && e.family != :preset
            f = @families[e.family]
            next false unless f&.document
            shipped ||= list.select { |d| d.family == :preset && d.shelf.shipped? }.to_h { |d| [d.name, true] }
            shipped.key?(f.document.call(e.name).to_sym)
          }
        end

        def document_entry(path, shelf)
          st = File.stat(path)
          @lock.synchronize do
            cached = @documents[path]
            return cached[2] if cached && cached[0] == st.mtime && cached[1] == st.size && cached[2]&.shelf == shelf
          end
          e = Library.document_entry(path, shelf)
          @lock.synchronize { @documents[path] = [st.mtime, st.size, e] }
          e
        rescue StandardError, ScriptError => e
          @lock.synchronize { @documents[path] = [st&.mtime, st&.size, nil] }
          problem(shelf, "document #{path}: #{e.message}")
          nil
        end

        # The Session's named racks as entries (the :session shelf).
        def session_entries
          s = defined?(MB::Sound::Session) && Session.existing
          return [] unless s
          shelf = Library.session_shelf
          from_files = file_entries.select { |e| Library.rack_of(e) }.map(&:name)
          s.racks.names.filter_map { |n|
            r = s.racks[n]
            next unless r
            next if from_files.include?(n) # (a library file's rack, placed by preset or use: its entry says more)
            kind = Library.rack_kind(r)
            Entry.new(name: n, kind: kind, family: :preset, shelf: shelf, location: 'session', builder: r, about: "#{r.kind} #{r.signature}")
          }
        rescue StandardError
          []
        end

        # Checks the file entries: collisions within a shelf, shipped
        # clashes (problems), and names shadowing others (a warning once
        # per entry, unless equal: a pinned copy).
        def check_files(list)
          code = @code.values
          by_key = (list + code).group_by { |e| [e.family, e.name] }
          by_key.each_value do |l|
            next if l.length < 2
            sorted = l.sort_by.with_index { |e, i| [e.shelf.rank, i] }
            winner = sorted.first
            sorted.drop(1).each do |other|
              if other.shelf == winner.shelf
                problem(winner.shelf, "file #{winner.label} is defined twice on the #{winner.shelf.name} shelf (#{winner.location}, #{other.location})")
              elsif !winner.same_as?(other)
                once("#{winner.label} from #{winner.location} shadows the #{other.shelf.name} shelf's (#{other.location}); find shows both")
              end
            end
          end
          list.each do |e|
            clash = word_clash(e, (list + code).reject { |o| o.equal?(e) })
            next unless clash
            e.shelf.shipped? ? problem(e.shelf, "file #{clash}") : once(clash)
          end
        end

        # Warns (once each) for pins whose built-in has changed since it
        # was pinned, or is gone (Library::Pins#change_warning).
        def check_pins(pins)
          pins.each do |pin|
            msg = Pins.change_warning(pin, shipped_entry(pin.family, pin.name))
            once(msg) if msg
          end
        end

        # The shipped entry of +family+ and +name+ (a built-in graph
        # document for :preset), or nil.
        def shipped_entry(family, name)
          return @code[[family, name]] unless family == :preset
          path = Library.document_path(Library.builtin_shelf.dir, name)
          path && document_entry(path, Library.builtin_shelf)
        end

        # A message if +entry+'s name is a tag or family word of another
        # entry under the same head, or one of its tags another entry's
        # name; else nil.
        def word_clash(entry, others)
          same = others.select { |o| o.kind == entry.kind && !(o.family == entry.family && o.name == entry.name) }
          families = @families.values.select { |f| f.kind == entry.kind }.map(&:name)
          if families.include?(entry.name)
            return "#{entry.label} (#{entry.location}) is named like the #{entry.name} family under L.#{HEADS.key(entry.kind)}; rename it (e.g. :#{entry.name}_#{entry.family})"
          end
          if (o = same.find { |x| x.tags.include?(entry.name) })
            return "#{entry.label} (#{entry.location}) is named like a tag of #{o.label} (#{o.location}); rename it (e.g. :#{entry.name}_#{entry.family}) or the tag (tags are adjectives and roles, names nouns)"
          end
          entry.tags.each do |t|
            if (o = same.find { |x| x.name == t })
              return "#{entry.label} (#{entry.location}) has tag #{t.inspect}, the name of #{o.label} (#{o.location}); rename the tag or the entry (e.g. :#{t}_#{o.family})"
            end
          end
          nil
        end

        # Records a problem; on shelves other than the shipped one it also
        # warns (once), since nothing else would say so.
        def problem(shelf, message)
          text = "#{shelf.name}: #{message}"
          added = @lock.synchronize { @problems.include?(text) ? false : (@problems << text) }
          once("#{text} (skipped)") if added && !shelf.shipped?
        end

        def once(message)
          first = @lock.synchronize { @warned.add?(message) }
          warn "Library: #{message}" if first
        end

        def score(entry, terms)
          return Hit.new(entry: entry, score: 0, matched: 0, why: []) if terms.empty?
          total = 0
          matched = 0
          why = []
          name = entry.name.to_s
          words = entry.name_words.map(&:to_s)
          head = HEADS.key(entry.kind)&.to_s
          about = entry.about.to_s.downcase
          terms.each do |t|
            best, label = [
              ([100, 'name'] if name == t),
              ([40, "name #{t}"] if words.include?(t)),
              ([30, "tag #{t}"] if entry.tags.any? { |g| g.to_s == t }),
              ([25, "#{entry.family == :preset ? 'kind' : 'family'} #{t}"] if entry.family.to_s == t || entry.kind.to_s == t || head == t),
              ([20, "name #{t}..."] if t.length >= 2 && name.start_with?(t)),
              ([12, "tag #{t}..."] if t.length >= 2 && entry.tags.any? { |g| g.to_s.start_with?(t) }),
              ([10, "name ~#{t}"] if t.length >= 3 && name.include?(t)),
              ([8, 'about'] if t.length >= 3 && about.match?(/\b#{Regexp.escape(t)}/)),
            ].compact.max_by(&:first)
            next unless best
            total += best
            matched += 1
            why << label
          end
          return nil if matched == 0
          Hit.new(entry: entry, score: total, matched: matched, why: why.uniq)
        end
      end
    end
  end
end
