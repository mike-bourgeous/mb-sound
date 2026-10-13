require 'pathname'

module MB
  module Sound
    # Graph documents: saving graphs as `.mbg.rb` files and loading them
    # back without running them as Ruby (design/notes/graph_io.md, phase 2).
    #
    # A document is the Ruby that GraphNode#to_ruby prints, after a short
    # header:
    #
    #     # mb-sound graph document: ...
    #     graph 2, name: "dark_hall", kind: :effect, saved: "2026-10-11T14:02:11Z", mb_sound: "0.12.0"
    #     inputs :input
    #     param :mix, 0.4, range: 0.0..1.0
    #
    #     input.reverb(:hall, mix: mix).softclip
    #
    # Loading parses it with Prism and walks the syntax tree (Loader):
    # literals, unit methods (.hz .db .ms .n8 .oct ...), Note constants,
    # the library's node classes, local variables, build blocks (synth
    # lanes, feedback loops, delay inserts), per_voice/per_channel, and DSL
    # calls checked against the recorded surface (Registry) and made with
    # public_send.  No if/case/loops/def/class, globals, instance
    # variables, backticks, send, eval, or const_get; anything else is a
    # GraphIO::LoadError naming the line, with a did_you_mean hint.
    #
    # Runtime blocks (`proc { |buf| buf * 0.5 }`) load when their bodies
    # stay within a safe subset (arithmetic and math on their own
    # parameters), else from named procs (`&named_proc(:fold)`, registered
    # with MB::Sound.named_proc), else only with `trust: :code`.
    #
    # Console (bin/sound.rb): `save :dark_hall, graph`, `preset :dark_hall,
    # input: mic, mix: 0.6`, `presets`, `ruby node` (to_ruby).
    module GraphIO
      # The document format version written by GraphIO.dump; documents of
      # newer versions don't load.  Format 2 (2026-10-13) marks seeds drawn
      # when the graph was built as `seed: drawn_seed(N)`; seeds: :fresh
      # redraws only those, keeping seeds the code gave (in format 1
      # documents, and in text without a header, every seed counts as
      # drawn).
      FORMAT = 2

      # The file extension of graph documents.
      EXTENSION = '.mbg.rb'

      # Resource limits for loading (override per load with +limits:+):
      # document bytes, syntax nodes, nesting depth, DSL calls made, build
      # time, delay times (positional, seconds:, max_delay:), silence and
      # until lengths, with_buffer sizes, oversampling factors, synth
      # voices, unison/swarm copies, and clip repeat counts.
      LIMITS = {
        bytes: 1_000_000,
        nodes: 250_000,
        depth: 400,
        calls: 100_000,
        build_seconds: 30,
        delay_seconds: 60,
        render_seconds: 600,
        buffer_samples: 1 << 20,
        oversample: 16,
        sample_rate: 768_000,
        voices: 64,
        copies: 64,
        repeats: 4096,
      }.freeze

      # A document that can't be loaded: syntax outside the subset, an
      # unknown method or name, a missing input, or a limit.  +line+ is the
      # line in the document (nil for whole-document problems).
      class LoadError < StandardError
        attr_reader :path, :line

        def initialize(message, path: nil, line: nil)
          super(message)
          @path = path
          @line = line
        end
      end

      # A graph that can't be saved (yet): +problems+ are the writer's
      # FIXMEs, +code+ what it printed.
      class DumpError < StandardError
        attr_reader :problems, :code

        def initialize(message, problems: [], code: nil)
          super(message)
          @problems = problems
          @code = code
        end
      end

      @procs = {}

      class << self
        # Named procs for runtime blocks outside the safe subset (see
        # MB::Sound.named_proc).
        attr_reader :procs

        # Builds the graph a document describes.  +source+ is a path (a
        # Pathname, or a String naming an existing file), or the document
        # text.  +inputs+ binds the document's inputs by name (missing ones
        # raise, extra ones warn); +params+ overrides its param defaults;
        # +trust: :code+ runs runtime blocks outside the safe subset as
        # Ruby (off by default; warns); +limits+ overrides LIMITS;
        # +base_dir+ is where relative file names point for text documents.
        #
        #     GraphIO.load('presets/dark_hall.mbg.rb', inputs: { input: mic }, params: { mix: 0.6 })
        #     GraphIO.load(220.hz.ramp.softclip.to_ruby)
        #
        # A set document (kind: :set, see SetWriter) loads into +session+
        # (the current one by default) and returns its Document.
        #
        # +seeds: :fresh+ leaves out every seed the save drew
        # (`seed: drawn_seed(N)`), so noise, random phases, and chance draw
        # new numbers (from the root random generator) instead of the saved
        # ones; a set's patches then draw anew each time a scene builds
        # them, like the set they were saved from.  Seeds the code gave
        # (e.g. `chance(0.5, seed: 7)`) stay.  Format 1 documents and text
        # without a header don't mark drawn seeds, so :fresh leaves out
        # every `seed:` they give.  The default, :saved, plays the same
        # every time.
        def load(source, inputs: {}, params: {}, trust: nil, limits: {}, base_dir: nil, session: nil, seeds: :saved)
          text, path = read_source(source)
          loader = Loader.new(text, path: path, inputs: inputs, params: params, trust: trust, limits: limits, base_dir: base_dir, session: session, seeds: seeds)
          graph = loader.load
          loader.document.input_objects = inputs.transform_keys(&:to_sym).slice(*loader.document.inputs)
          graph
        end

        # Reads a document's header (format, metadata, inputs, params)
        # without building its graph.  Returns a Document.
        def parse(source)
          text, path = read_source(source)
          loader = Loader.new(text, path: path)
          loader.read_document
        end

        # The document text for +graph+ (a node, bundle, Synth, or Array of
        # nodes): a header (name, kind, saved time, mb-sound version, the
        # script it came from, baked script +options+), `inputs`, and a
        # `param` line for each of +params+ the graph uses as a knob (a
        # Constant named after the param with its value), a `knob` line for
        # each GraphNode::Knob in the graph (its held value; a moving knob
        # saves its current value after a comment), then the graph
        # as GraphNode#to_ruby prints it, with seeds.  +inputs+ names free
        # inputs ({ midi: notes }).  A loaded graph keeps its Document, so
        # its name, inputs, and params carry over.  Raises DumpError if
        # part of the graph can't be written yet.
        #
        # +assets+ (an Assets) names files for tables and sound or MIDI
        # files the graph reads (bundles; see .save); without it they raise
        # DumpError (tables) or keep their paths (file names).
        def dump(graph, name: nil, kind: nil, inputs: {}, params: {}, options: {}, from: nil, meta: {}, assets: nil)
          if graph.is_a?(Arrangement)
            unless inputs.empty? && params.empty? && options.empty? && kind.nil?
              raise ArgumentError, 'set documents take no inputs, params, options, or kind'
            end
            w = SetWriter.new(graph, name: name, meta: meta, assets: assets, from: from)
            text = w.to_s
            w.warnings.uniq.each { |m| warn "#{name || 'set'}: #{m}" } unless assets&.entries&.any?(&:sha256)
            return text
          end
          Writer.new(graph, name: name, kind: kind, inputs: inputs, params: params, options: options, from: from, meta: meta, assets: assets).to_s
        end

        # Writes +graph+'s document to +target+ (a preset name, saved in
        # .presets_dir, or a path ending in .mbg.rb).  Returns the path of
        # the document.
        #
        # A graph that reads files (wavetables and samples that aren't
        # library tables, MIDI files, sound files) is saved as a bundle: a
        # directory `name.mbg/` with `name.mbg.rb` and the files in
        # `assets/` (see Assets), replacing a plain document of the same
        # name and the other way around.  +bundle: true+ always makes a
        # bundle, +false+ never (raising DumpError if the graph reads
        # files).
        def save(target, graph, bundle: nil, **opts)
          require 'fileutils'
          path = target_path(target)
          name = opts.delete(:name) || File.basename(path).delete_suffix(EXTENSION)
          assets = Assets.new
          text = dump(graph, name: name, assets: assets, **opts)
          dir = bundle_dir(path)

          if assets.empty? && bundle != true
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, text)
            remove_bundle(dir)
            return path
          end
          if bundle == false
            raise DumpError.new("#{name} reads files (#{assets.entries.map { |e| File.basename(e.name) }.join(', ')}), which only a bundle can hold (save with bundle: true or nil)")
          end

          # Files first, in a new directory that replaces the old bundle
          # (whose files may be the sources)
          stage = "#{dir}.saving-#{Process.pid}"
          FileUtils.rm_rf(stage)
          begin
            assets.write(stage)
            text = dump(graph, name: name, assets: assets, **opts)
            File.write(File.join(stage, File.basename(path)), text)
            remove_bundle(dir)
            File.rename(stage, dir)
          ensure
            FileUtils.rm_rf(stage)
          end
          FileUtils.rm_f(path)
          File.join(dir, File.basename(path))
        end

        # The bundle directory for document path +path+ (x.mbg.rb -> x.mbg).
        def bundle_dir(path)
          path.delete_suffix('.rb')
        end

        # The document inside bundle directory +dir+: dir/<name>.mbg.rb,
        # else its only .mbg.rb file, else nil.
        def bundle_document(dir)
          own = File.join(dir, "#{File.basename(dir).delete_suffix('.mbg')}#{EXTENSION}")
          return own if File.file?(own)
          docs = Dir[File.join(dir, "*#{EXTENSION}")]
          docs.length == 1 ? docs[0] : nil
        end

        # The Document of a graph built by .load, or nil.
        def document_of(graph)
          return nil unless graph.instance_variable_defined?(:@graph_io_document)
          graph.instance_variable_get(:@graph_io_document)
        end

        # The directory presets are saved to: $MB_SOUND_PRESETS, else the
        # project's presets/ (see .project_dir), else the user data
        # directory (~/Library/Application Support/mb-sound/presets on
        # macOS, $XDG_DATA_HOME/mb-sound/presets or
        # ~/.local/share/mb-sound/presets elsewhere).
        def presets_dir
          env = ENV['MB_SOUND_PRESETS']
          return File.expand_path(env) unless env.to_s.empty?
          project = project_dir
          return File.join(project, 'presets') if project
          user_presets_dir
        end

        # The user data directory for presets.
        def user_presets_dir
          if RUBY_PLATFORM.include?('darwin')
            File.join(Dir.home, 'Library', 'Application Support', 'mb-sound', 'presets')
          else
            base = ENV['XDG_DATA_HOME'].to_s.empty? ? File.join(Dir.home, '.local', 'share') : ENV['XDG_DATA_HOME']
            File.join(base, 'mb-sound', 'presets')
          end
        end

        # The song or album project around the working directory: the
        # nearest directory up with a Gemfile naming mb-sound (other than
        # the mb-sound checkout itself), or nil.
        def project_dir(from = Dir.pwd)
          dir = File.expand_path(from)
          loop do
            gemfile = File.join(dir, 'Gemfile')
            if File.file?(gemfile) && !File.exist?(File.join(dir, 'mb-sound.gemspec')) &&
                File.read(gemfile).match?(/^\s*gem\s+['"]mb-sound['"]/)
              return dir
            end
            parent = File.dirname(dir)
            return nil if parent == dir
            dir = parent
          end
        end

        # Directories searched for presets, in order (the save directory
        # first, then the user directory).
        def preset_dirs
          [presets_dir, user_presets_dir].uniq
        end

        # The file of preset +name+ (the first found in .preset_dirs), or
        # nil.
        def find_preset(name)
          file = "#{name}#{EXTENSION}"
          preset_dirs.each do |d|
            plain = File.join(d, file)
            return plain if File.file?(plain)
            bundle = bundle_dir(plain)
            return bundle_document(bundle) if File.directory?(bundle) && bundle_document(bundle)
          end
          nil
        end

        # Preset names by directory ({ dir => [names] }), plain documents
        # and bundles alike.
        def presets
          preset_dirs.to_h { |d|
            plain = Dir[File.join(d, "*#{EXTENSION}")].select { |p| File.file?(p) }
            bundles = Dir[File.join(d, '*.mbg')].select { |p| File.directory?(p) && bundle_document(p) }
            names = plain.map { |p| File.basename(p).delete_suffix(EXTENSION) } + bundles.map { |p| File.basename(p).delete_suffix('.mbg') }
            [d, names.uniq.sort.map(&:to_sym)]
          }
        end

        # " (did you mean ...?)" for +name+ among +candidates+, or "".
        def suggest(name, candidates)
          require 'did_you_mean'
          found = DidYouMean::SpellChecker.new(dictionary: candidates.map(&:to_s)).correct(name.to_s)
          found.empty? ? '' : " (did you mean #{found.first(3).join(', ')}?)"
        rescue NameError, LoadError
          ''
        end

        # mb-sound's version, with the git commit when the library is a
        # checkout.
        def library_version
          @library_version ||= begin
            root = File.expand_path('../..', __dir__)
            head = File.join(root, '..', '.git')
            commit = nil
            if File.exist?(head)
              commit = IO.popen(['git', '-C', root, 'rev-parse', '--short', 'HEAD'], err: File::NULL, &:read).strip rescue nil
              commit = nil if commit&.empty?
            end
            commit ? "#{MB::Sound::VERSION} (#{commit})" : MB::Sound::VERSION
          end
        end

        private

        # [text, path] for a load source.
        def read_source(source)
          case source
          when Pathname
            read_source(source.to_s)
          when String
            if !source.include?("\n") && File.directory?(source)
              doc = bundle_document(source)
              raise LoadError.new("no graph document in #{source} (a bundle holds name.mbg.rb)", path: source) unless doc
              [File.read(doc), doc]
            elsif !source.include?("\n") && source.end_with?('.rb') && File.file?(source)
              [File.read(source), source]
            elsif !source.include?("\n") && source.end_with?('.rb')
              raise LoadError.new("no graph document at #{source}", path: source)
            else
              [source, nil]
            end
          else
            raise ArgumentError, "GraphIO.load takes a path or document text (got #{source.class})"
          end
        end

        # Removes bundle directory +dir+ if it is one (a document and
        # assets/ only); raises for other directories.
        def remove_bundle(dir)
          return unless File.directory?(dir)
          extra = Dir.children(dir) - [Assets::DIR] - Dir.children(dir).grep(/#{Regexp.escape(EXTENSION)}\z/)
          raise DumpError.new("#{dir} holds other files (#{extra.first(3).join(', ')}); not replacing it") unless extra.empty?
          FileUtils.rm_rf(dir)
        end

        public

        # The file GraphIO.save writes for +target+ (a preset name or a
        # path).
        def target_path(target)
          t = target.to_s
          if t.include?('/') || t.end_with?('.rb')
            t = "#{t}#{EXTENSION}" unless t.end_with?(EXTENSION)
            File.expand_path(t)
          else
            raise ArgumentError, "preset names are words (got #{target.inspect})" unless t.match?(/\A[\w.-]+\z/) && !t.start_with?('.')
            File.join(presets_dir, "#{t}#{EXTENSION}")
          end
        end
      end
    end

    # The console's save, preset, presets, and named_proc (bin/sound.rb).
    module GraphIOMethods
      # Saves +graph+ as preset +name+ (a Symbol; or a path ending in
      # .mbg.rb) and prints where.  Returns the path.  Options as for
      # GraphIO.dump (inputs:, params:, ...).
      #
      #     save :dark_hall, input.reverb(:hall).softclip
      def save(name, graph, **opts)
        target = GraphIO.target_path(name)
        existed = File.file?(target) || File.directory?(GraphIO.bundle_dir(target))
        path = GraphIO.save(name, graph, **opts)
        puts "Saved #{name} to #{path}#{' (replaced)' if existed}"
        path
      rescue GraphIO::DumpError => e
        warn "Not saved: #{e.message}"
        nil
      end

      # Loads preset +name+ (from GraphIO.preset_dirs; or a path) with the
      # document's inputs and param overrides given as keywords, e.g.
      # `preset :dark_hall, input: mic, mix: 0.6`.  +trust: :code+ allows
      # runtime blocks outside the safe subset.
      #
      # The document's knobs join +session+ right away (the session console
      # commands use, if one exists; false for none; see
      # Session::Knobs#adopt_knobs), so `turn :cut` works before the graph
      # plays; a knob with a MIDI controller (`cc:`) listens to live input.
      # An override of a knob that joins an existing Session knob turns
      # the shared knob now (a journaled, undoable turn, as `turn :cut,
      # 900` would).
      #
      # A set document (`save :gig, set`) loads into +session+ (the current
      # Session by default): its tempo, knobs, master chain, tracks,
      # scenes, mute groups, and flow, returning the Document (`play_form
      # doc.form`, or `go :intro`).
      #
      # +seeds: :fresh+ draws new random seeds instead of the saved ones
      # (see GraphIO.load; seeds the code gave stay).
      def preset(name, trust: nil, session: nil, seeds: :saved, **inputs_and_params)
        path = name.to_s.include?('/') || name.to_s.end_with?('.rb') ? name.to_s : GraphIO.find_preset(name)
        unless path
          names = GraphIO.presets.values.flatten
          raise GraphIO::LoadError, "no preset #{name}#{GraphIO.suggest(name, names)} (looked in #{GraphIO.preset_dirs.join(', ')})"
        end

        doc = GraphIO.parse(path)
        if doc.kind == :set
          raise ArgumentError, "a set takes no inputs (got #{inputs_and_params.keys.join(', ')})" unless inputs_and_params.empty?
          doc = GraphIO.load(path, trust: trust, session: session || Session.current, seeds: seeds)
          puts "Loaded set #{doc.name}: tracks #{doc.session.arrangement.tracks.keys.join(', ')}; scenes #{doc.session.arrangement.scenes.keys.join(', ')}#{'; play_form doc.form plays its flow' if doc.form}"
          return doc
        end
        params = inputs_and_params.select { |k, _| doc.params.key?(k) }
        inputs = inputs_and_params.reject { |k, _| doc.params.key?(k) }
        graph = GraphIO.load(path, inputs: inputs, params: params, trust: trust, seeds: seeds)

        session = Session.existing if session.nil?
        if session
          before = session.knobs
          joined = session.adopt_knobs(graph)
          attach_knob_midi(session, joined)
          joined.each do |n, _k|
            next unless before[n] && params.key?(n)
            if Session.context&.[](:session).equal?(session)
              turn(n, params[n])
            else
              Session.with_context(session: session) { turn(n, params[n]) }
            end
          end
        end

        graph
      end

      # Lists the presets by directory (names with their inputs and params).
      # Returns the names.
      def presets
        all = GraphIO.presets
        all.each do |dir, names|
          puts "#{dir}:"
          puts '  (none)' if names.empty?
          names.each do |n|
            doc = GraphIO.parse(File.join(dir, "#{n}#{GraphIO::EXTENSION}")) rescue nil
            extra = []
            extra << "inputs: #{doc.inputs.join(', ')}" if doc && !doc.inputs.empty?
            extra << "params: #{doc.param_values.map { |k, v| "#{k} #{v}" }.join(', ')}" if doc && !doc.params.empty?
            puts "  #{n}#{"  (#{extra.join('; ')})" unless extra.empty?}"
          end
        end
        all.values.flatten.uniq
      end

      # The set of the current Session (its Arrangement: tracks, scenes,
      # knobs, flow), for `save :gig, set`.  Also available as
      # #current_set.
      def set
        Session.current.arrangement
      end
      alias current_set set

      # Registers a runtime block under +name+ for graph documents
      # (`sig.proc(&named_proc(:fold))` saves and loads as that name), or
      # returns the registered block without one.
      #
      #     fold = named_proc(:fold) { |buf| (buf * 3).sin }
      #     220.hz.ramp.proc(&fold)
      def named_proc(name, &block)
        name = name.to_sym
        if block
          GraphIO.procs[name] = block
        else
          GraphIO.procs.fetch(name) { raise ArgumentError, "no named proc #{name.inspect}#{GraphIO.suggest(name, GraphIO.procs.keys)}" }
        end
      end
    end
    extend GraphIOMethods
  end
end

require_relative 'graph_io/registry'
require_relative 'graph_io/document'
require_relative 'graph_io/loader'
require_relative 'graph_io/trusted_code'
require_relative 'graph_io/file_guard'
require_relative 'graph_io/assets'
require_relative 'graph_io/set_writer'
