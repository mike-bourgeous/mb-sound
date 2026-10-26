module MB
  module Sound
    # The library: presets at every scale in one index (library-core-1,
    # 2026-10-26; the maintainer's design is in the workbench,
    # research/library-design/; the notes in design/notes/library.md).
    #
    # - Library::Entry: one frozen value per named thing (a reverb preset,
    #   an instrument, a graph document, a drum machine, a clip)
    # - Library::Index (Library.index): every entry, from the class presets
    #   (Presettable), entries registered in code, and the shelves' library
    #   files and graph documents, searched in SHELF_ORDER; #find
    # - Presettable: `extend Presettable` and `preset :hall, ...` lines in a
    #   class body
    # - library files (FileLoader): Ruby files on a shelf (presets/fx/reverb.rb
    #   holding `reverb :plate, decay: 2, tags: %i[bright]`), read like graph
    #   documents (Prism, no eval)
    # - console commands (LibraryMethods): find, save!, collect, promote,
    #   shelves; heads under MB::Sound::L (L.fx.reverb.hall)
    module Library
      # The head words under MB::Sound::L and the kinds they list (the
      # word heads are provisional: maintainer, 2026-10-26).
      HEADS = {
        inst: :instrument, fx: :effect, notes: :note_fx, listen: :listener, mod: :modulator,
        kit: :kit, seq: :clip, master: :master, set: :set, env: :envelope, edit: :sample_edit,
      }.freeze

      # The library file format's version (`library 1` at the top of a file;
      # optional).
      FORMAT = 1

      # Words of graph document names that become tags (the genre prefix of
      # the persona panel's presets: dnb_reese is tagged dnb).
      GENRE_WORDS = %i[dnb jungle ambient funk house techno sq80].freeze

      class << self
        # The process's Index.
        def index
          @index ||= Index.new
        end

        # The families by name (see Family).
        def families
          index.families
        end

        # The shelf of mb-sound's own entries (class presets and its
        # presets/ folder).
        def builtin_shelf
          @builtin_shelf ||= Shelf.new(name: :builtin, dir: File.expand_path('../../../presets', __dir__), label: 'built-in')
        end

        # The shelf of the current Session's named racks.
        def session_shelf
          @session_shelf ||= Shelf.new(name: :session, label: 'session')
        end

        # The shelves in search order (SHELF_ORDER): the Session's racks,
        # $MB_SOUND_PRESETS or else the project's presets/, the user shelf,
        # gems naming a shelf (metadata 'mb_sound_shelf', a directory in
        # the gem), mb-sound's built-ins.  The first match wins.
        def shelves
          key = shelves_key
          cached = @shelves
          return cached[1] if cached && cached[0] == key

          list = [session_shelf]
          env = ENV['MB_SOUND_PRESETS']
          if !env.to_s.empty?
            list << Shelf.new(name: :env, dir: env, label: "$MB_SOUND_PRESETS #{File.expand_path(env)}")
          elsif (project = GraphIO.project_dir)
            list << Shelf.new(name: :project, dir: File.join(project, 'presets'), label: "project #{File.join(project, 'presets')}")
          end
          user = user_dir
          list << Shelf.new(name: :user, dir: user, label: "user #{user}") unless list.any? { |s| s.dir == File.expand_path(user) }
          gem_shelves.each { |s| list << s }
          list << builtin_shelf
          list.freeze
          @shelves = [key, list]
          list
        end

        # The shelf named +name+ (:env, :project, :user, :gem, :builtin;
        # the first of that name), or nil.
        def shelf(name)
          shelves.find { |s| s.name == name }
        end

        # The shelf saves go to: $MB_SOUND_PRESETS, else the project's,
        # else the user's (GraphIO.presets_dir).
        def save_shelf
          shelves.find { |s| %i[env project user].include?(s.name) }
        end

        # The user shelf's directory: $MB_SOUND_USER_PRESETS, else the user
        # data directory (see GraphIO.user_presets_dir).
        def user_dir
          GraphIO.user_presets_dir
        end

        # Shelves of gems in the bundle whose gemspec metadata names one
        # (`spec.metadata['mb_sound_shelf'] = 'presets'`).
        def gem_shelves
          Gem.loaded_specs.values.filter_map { |spec|
            rel = spec.metadata && spec.metadata['mb_sound_shelf']
            next if rel.to_s.empty? || spec.name == 'mb-sound'
            dir = File.expand_path(rel, spec.full_gem_path)
            Shelf.new(name: :gem, dir: dir, label: "gem #{spec.name} #{dir}")
          }.sort_by(&:label)
        rescue StandardError
          []
        end

        # Library files under +dir+: Ruby files that aren't graph documents
        # (*.mbg.rb) or inside bundles (*.mbg/), sorted.
        def library_files(dir)
          Dir.glob('**/*.rb', base: dir).reject { |p|
            p.end_with?(GraphIO::EXTENSION) || p.split('/').any? { |part| part.end_with?('.mbg') || part.start_with?('.') }
          }.sort.map { |p| File.join(dir, p) }
        end

        # Graph document files directly in +dir+ (plain documents, then
        # bundles of names without a plain document), sorted by name.
        def document_paths(dir)
          names = Dir[File.join(dir, "*#{GraphIO::EXTENSION}")].select { |p| File.file?(p) }.map { |p| File.basename(p).delete_suffix(GraphIO::EXTENSION) }
          names += Dir[File.join(dir, '*.mbg')].select { |p| File.directory?(p) }.map { |p| File.basename(p).delete_suffix('.mbg') }
          names.uniq.sort.filter_map { |n| document_path(dir, n) }
        end

        # The document for preset +name+ in +dir+ (a plain document, else a
        # bundle's), or nil: GraphIO.find_preset's rule for one directory.
        def document_path(dir, name)
          plain = File.join(dir, "#{name}#{GraphIO::EXTENSION}")
          return plain if File.file?(plain)
          bundle = GraphIO.bundle_dir(plain)
          File.directory?(bundle) ? GraphIO.bundle_document(bundle) : nil
        end

        # An Entry for the graph document at +path+ on +shelf+ (header only):
        # kind from the header (synths are instruments, rack documents by
        # their rack), tags from the header's tags: and a genre word
        # starting the name (GENRE_WORDS), about from description:.
        def document_entry(path, shelf)
          doc = GraphIO.parse(path)
          name = (doc.name || File.basename(path).delete_suffix(GraphIO::EXTENSION)).to_s
          name = File.basename(path).delete_suffix(GraphIO::EXTENSION) unless name.match?(/\A[\w.-]+\z/)
          kind = document_kind(doc)
          tags = Array(doc.meta[:tags]).select { |t| t.is_a?(Symbol) || t.is_a?(String) }
          first = name.split('_').first&.to_sym
          tags = [first, *tags] if first && GENRE_WORDS.include?(first) && name.include?('_')
          params = doc.declarations rescue {}
          about = doc.description&.then { |d| d.split(/(?<=\.)\s/).first }
          inputs = doc.inputs
          Entry.new(
            name: name.to_sym, kind: kind, family: :preset, tags: tags, about: about, params: params.is_a?(Hash) ? params.select { |_, v| v.is_a?(MB::Sound::Param) } : {},
            shelf: shelf, location: path, settings: { inputs: inputs, document: true }, builder: ->(**kw) { MB::Sound.preset(path, **kw) }
          )
        end

        # The kind of a parsed graph Document.
        def document_kind(doc)
          if doc.rack?
            ctor = doc.meta[:rack]
            return :instrument if %i[irack instrument_rack].include?(ctor)
            return :listener if %i[lrack amrack listener_rack].include?(ctor)
            types = doc.input_types
            return Rack::KINDS[[types.values.first, doc.outputs.first]] || Rack::DEFAULT_KINDS[types.values.first] || :effect
          end
          case doc.kind
          when :set then :set
          when :effect then :effect
          when :synth, :instrument then :instrument
          else
            doc.input_types.values.first == :audio ? :effect : :instrument
          end
        end

        # The kind of an Entry for Rack +r+.
        def rack_kind(r)
          k = r.kind
          KINDS.include?(k) ? k : :effect
        end

        # Words of a find query (a String, Symbol, or Array of them),
        # lowercased.
        def terms(query)
          Array(query).flat_map { |q| q.to_s.downcase.split(/[\s,]+/) }.reject(&:empty?).map { |t| t.delete_prefix(':') }
        end

        # "\nDid you mean?  :x" for +name+ among +names+ (or "").
        def suggest(name, names)
          require 'did_you_mean'
          found = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(name.to_s).map { |n| n.to_sym.inspect }
          found.empty? ? '' : "\nDid you mean?  #{found.join("\n                ")}"
        end

        # A deep-frozen copy of +v+ (Hashes, Arrays, Strings).
        def deep_freeze(v)
          case v
          when Hash then v.to_h { |k, x| [deep_freeze(k), deep_freeze(x)] }.freeze
          when Array then v.map { |x| deep_freeze(x) }.freeze
          when String then v.frozen? ? v : v.dup.freeze
          else v
          end
        end

        # Defines +rack+ (a library file's instrument or chain) in the
        # current Session under its name, as `preset` does with rack
        # documents (GraphIO.place_rack: the same definition reuses the
        # session's; a different one settles as a rack conflict).  Returns
        # the rack to use.
        def place(rack, source: nil)
          session = Session.context&.[](:session) || Session.current
          GraphIO.place_rack(session, rack, source: source)
        end

        # The Rack of a library-file rack entry (see #remember_rack), or nil.
        def rack_of(entry)
          RACKS[entry]
        end

        # Remembers +rack+ as +entry+'s (FileLoader).
        def remember_rack(entry, rack)
          RACKS[entry] = rack
        end

        # Params of a rack's block (a Prism BlockNode): its literal `knob
        # :name, default, ...` lines, read as graph-document knob lines.
        def rack_params(block)
          lines = []
          stack = [block.body]
          until stack.empty?
            n = stack.pop
            next if n.nil?
            if n.is_a?(Prism::CallNode) && n.name == :knob && n.receiver.nil? && n.block.nil? &&
               (a = n.arguments&.arguments) && a.length >= 2 && a[0].is_a?(Prism::SymbolNode)
              lines << n.slice
            end
            n.compact_child_nodes.each { |c| stack << c }
          end
          return {} if lines.empty?
          doc = GraphIO.parse(lines.reverse.uniq.join("\n") + "\n")
          doc.declarations
        rescue StandardError
          {}
        end

        # Reads the shelves' files again on next use (see Index#reload!).
        def reload!
          @shelves = nil
          index.reload!
        end

        private

        def shelves_key
          [Dir.pwd, ENV['MB_SOUND_PRESETS'], ENV['MB_SOUND_USER_PRESETS'], ENV['XDG_DATA_HOME'], ENV['HOME'], Gem.loaded_specs.size]
        end
      end
    end
  end
end

require_relative 'library/entry'
require_relative 'library/index'
require_relative 'library/presettable'

module MB
  module Sound
    module Library
      # Racks of library-file entries (see .rack_of).
      RACKS = ObjectSpace::WeakKeyMap.new

      autoload :FileLoader, File.expand_path('library/file_loader', __dir__)
    end
  end
end
