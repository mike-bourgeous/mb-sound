require 'fileutils'
require 'open3'
require 'rbconfig'

module MB
  module Sound
    module SoundGuard
      # One golden-set piece: a song script with options (rendered as a
      # process: `ruby -Ilib SCRIPT -q -f -o OUT ARGS`), or a block that
      # returns a graph (a preset on a phrase), rendered for +bars+ at
      # +bpm+ in a process of its own by golden/render_piece.rb.
      #
      # +genre+ is the maintainer's genre list entry it stands for, +covers+
      # what library areas it exercises.
      Piece = Data.define(:name, :script, :args, :block, :bars, :bpm, :genre, :covers) do
        def script? = !script.nil?

        # The command that renders this piece to +out+ from the repository
        # root +root+ (an Array for Process.spawn).
        def command(out, root:)
          ruby = [RbConfig.ruby, '-I', File.join(root, 'lib')]
          if script?
            ruby + [File.join(root, script), '-q', '-f', '-o', out, *args]
          else
            ruby + [File.join(root, 'golden', 'render_piece.rb'), name.to_s, out]
          end
        end

        # The shell command a person runs from the repository root to render
        # it (for reports and Bench code).
        def shell_command(out = "#{name}.flac")
          if script?
            ['bundle exec ruby -Ilib', script, '-q -f -o', out, *args].join(' ')
          else
            "bundle exec ruby -Ilib golden/render_piece.rb #{name} #{out}"
          end
        end

        # Renders a block piece in this process (golden/render_piece.rb).
        def render_here(out)
          raise ArgumentError, "#{name} is a script piece" if script?
          MB::Sound.seed(1)
          graph = MB::Sound.instance_exec(&block)
          MB::Sound.render(out, graph, bars: bars, bpm: bpm, overwrite: true)
        end
      end

      # The golden set's definition (golden/set.rb): a builder whose
      # `piece` calls add Pieces.
      class GoldenSet
        # The definition file, relative to the repository root.
        DEFINITION = 'golden/set.rb'

        # Committed fingerprints, relative to the repository root.
        FINGERPRINTS = 'golden/fingerprints'

        attr_reader :pieces, :root, :fingerprints_dir

        # Loads golden/set.rb from repository +root+.
        def self.load(root = SoundGuard.root)
          set = new(root)
          SoundGuard.loading(set) { Kernel.load(File.join(root, DEFINITION)) }
          set
        end

        # An empty set rendering from repository +root+, keeping fingerprints
        # in +fingerprints_dir+ (golden/fingerprints there by default).
        def initialize(root, fingerprints_dir: File.join(root, FINGERPRINTS))
          @root = root
          @fingerprints_dir = fingerprints_dir
          @pieces = {}
        end

        # Adds a piece (see golden/set.rb).  Script pieces give the script
        # and its options; block pieces give bars: and bpm: and a block
        # returning the graph.
        def piece(name, script = nil, *args, genre:, covers:, bars: nil, bpm: nil, &block)
          name = name.to_sym
          raise ArgumentError, "Golden piece #{name.inspect} is defined twice" if @pieces.key?(name)
          raise ArgumentError, "Golden piece #{name.inspect} needs a script or a block, not both" if script.nil? == block.nil?
          raise ArgumentError, "Golden piece #{name.inspect} needs bars: and bpm:" if block && (bars.nil? || bpm.nil?)
          if script && !File.exist?(File.join(@root, script))
            raise ArgumentError, "Golden piece #{name.inspect}: no script #{script}"
          end
          @pieces[name] = Piece.new(name, script, args.map(&:to_s).freeze, block, bars, bpm, genre, covers)
        end

        # Pieces named in +names+ (Symbols or Strings; all when empty),
        # raising with suggestions for unknown names.
        def select(names)
          return @pieces.values if names.nil? || names.empty?
          names.map { |n|
            @pieces.fetch(n.to_sym) {
              raise ArgumentError, "No golden piece #{n.inspect}#{GraphIO.suggest(n.to_sym, @pieces.keys)}"
            }
          }
        end

        def fingerprint_path(piece)
          File.join(@fingerprints_dir, "#{piece.name}.json")
        end

        def approved_fingerprint(piece)
          path = fingerprint_path(piece)
          File.exist?(path) ? Fingerprint.load(path) : nil
        end
      end

      @loading = nil

      # The set a golden/set.rb being loaded adds to.
      def self.golden_set(&block)
        raise 'golden_set is called from golden/set.rb while SoundGuard loads it' unless @loading
        @loading.instance_exec(&block)
      end

      def self.loading(set)
        @loading = set
        yield
      ensure
        @loading = nil
      end

      # The repository root holding this library.
      def self.root
        File.expand_path('../../../../..', __FILE__)
      end

      # Where approved renders and check runs live (not in git): the
      # MB_SOUND_GOLDEN_DIR environment variable, else tmp/golden in the
      # main checkout (shared by every worktree of the repository), else
      # tmp/golden here.
      def self.golden_dir(root = self.root)
        env = ENV['MB_SOUND_GOLDEN_DIR']
        return File.expand_path(env) unless env.nil? || env.empty?
        common, status = Open3.capture2('git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir', err: File::NULL)
        main = status.success? ? File.dirname(common.strip) : root
        File.join(main, 'tmp', 'golden')
      end

      # The current commit of +root+ (short), or nil.
      def self.commit(root = self.root)
        out, status = Open3.capture2('git', '-C', root, 'rev-parse', '--short=10', 'HEAD', err: File::NULL)
        status.success? ? out.strip : nil
      end
    end
  end
end
