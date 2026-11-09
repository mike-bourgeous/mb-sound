module MB
  module Sound
    # Finds the local copy of a file that a foreign project, instrument, or
    # module names by a path from another machine (importer-media-1,
    # 2026-11-09; design/notes/importers.md).
    #
    # An index walks a media root once and lists its files by name (case
    # insensitive, Unicode NFC).  #resolve takes a saved path (Windows
    # `D:\Loops\Drums\Kick.wav` or POSIX, absolute or relative) and finds
    # the file of that name; when several files share it, the one whose
    # trailing folders match the saved path's best wins (ties: the first in
    # path order), and the Match says so:
    #
    #     media = MB::Sound::MediaIndex.for('/music/media')
    #     m = media.resolve('D:\\Loops\\Drums\\Kick.wav')
    #     m.path        # => "/music/media/pack/Drums/kick.wav", or nil
    #     m.status      # => :found, :ambiguous (several named so), :missing
    #     m.folders     # => 1 (folders above the name that matched)
    #     m.candidates  # => every file of that name, best first
    #     media['D:\\Loops\\Drums\\Kick.wav']  # just the path
    #
    # .for keeps one index per root and options, reused while none of the
    # root's folders changed (their mtimes; a file's contents don't matter
    # to a name index).  Symbolic links to files are listed; links to
    # folders are not followed (like Dir.glob's **).  Files and folders
    # whose names start with a dot are left out unless hidden: true.
    class MediaIndex
      # One resolution: the saved +foreign+ path, the local +path+ chosen
      # (nil if none), +status+ (:found for the only file of that name,
      # :ambiguous when several share it, :missing), +folders+ (the chosen
      # file's folders that matched the saved path's, counted up from the
      # name; nil when missing), +candidates+ (every file of the name, best
      # first), and +tied+ (how many candidates matched as many folders as
      # the chosen one, itself included).
      Match = Struct.new(:foreign, :path, :status, :folders, :candidates, :tied) do
        def found? = !path.nil?
        def missing? = status == :missing
        def ambiguous? = status == :ambiguous

        # A one-line description for warnings (nil unless ambiguous).
        def message
          return nil unless ambiguous?

          how = tied > 1 ? "#{tied} tied at #{folders} matching folder#{'s' if folders != 1}, took the first" : "#{folders} matching folder#{'s' if folders != 1}"
          "#{candidates.length} files named #{File.basename(path)} for #{foreign}: chose #{path} (#{how}); " \
            "others: #{(candidates - [path]).join(', ')}"
        end
      end

      # Indexes kept by .for at most (the least recently used goes first).
      CACHE_SIZE = 8

      @cache = {}
      @cache_lock = Mutex.new

      class << self
        # The index of +root+ with these options, from the cache while its
        # folders are unchanged, else walked again (see #fresh?).
        def for(root, hidden: false, extensions: nil)
          key = [File.expand_path(root.to_s), hidden, extensions&.map { |e| normalize_extension(e) }&.sort].freeze
          @cache_lock.synchronize do
            idx = @cache.delete(key)
            idx = nil if idx && !idx.fresh?
            idx ||= new(key[0], hidden: hidden, extensions: extensions)
            @cache[key] = idx
            @cache.delete(@cache.keys.first) while @cache.length > CACHE_SIZE
            idx
          end
        end

        # Forgets every cached index.
        def clear_cache
          @cache_lock.synchronize { @cache.clear }
        end

        # The lookup form of a file or folder name: Unicode NFC, lower case
        # (invalid bytes replaced).
        def key(name)
          s = name.to_s
          s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
          s = s.scrub unless s.valid_encoding?
          s.unicode_normalize(:nfc).downcase
        end

        # The lookup forms of a saved path's parts (Windows or POSIX
        # separators; empty and `.` parts left out).
        def parts(path)
          path.to_s.tr('\\', '/').split('/').reject { |p| p.empty? || p == '.' }.map { |p| key(p) }
        end

        # ".wav" for "wav", ".WAV", or ".wav".
        def normalize_extension(ext)
          e = key(ext)
          e.start_with?('.') ? e : ".#{e}"
        end
      end

      attr_reader :root

      # Walks +root+ (a folder) and indexes its files.  +hidden+ includes
      # names starting with a dot; +extensions+ (e.g. %w[wav flac]) limits
      # the index to those file types.
      def initialize(root, hidden: false, extensions: nil)
        @root = File.expand_path(root.to_s)
        raise ArgumentError, "No media folder #{root.to_s.inspect}" unless File.directory?(@root)

        @hidden = hidden
        @extensions = extensions&.map { |e| self.class.normalize_extension(e) }
        @files = Hash.new { |h, k| h[k] = [] }
        @folders = {}
        @warned = {}
        @warn_lock = Mutex.new
        walk(@root)
        @files.each_value(&:sort!)
        @files.default_proc = nil
        @files.each_value(&:freeze)
        @files.freeze
        @folders.freeze
      end

      # The number of files indexed.
      def size
        @files.sum { |_, list| list.length }
      end

      # Every file named +name+ (any case), in path order.
      def files(name)
        @files.fetch(self.class.key(File.basename(name.to_s.tr('\\', '/'))), [].freeze)
      end

      # The names (lookup forms) of which several files exist: { name =>
      # paths }.
      def ambiguous
        @files.select { |_, list| list.length > 1 }
      end

      # The Match for the saved path +foreign+ (see Match).  With +warn+,
      # an ambiguous match prints Match#message once per saved path and
      # choice.
      def resolve(foreign, warn: false)
        want = self.class.parts(foreign)
        list = want.empty? ? [] : files(want.last)
        return Match.new(foreign, nil, :missing, nil, [].freeze, 0) if list.empty?
        return Match.new(foreign, list[0], :found, score(list[0], want) - 1, list, 1) if list.length == 1

        scored = list.each_with_index.map { |f, i| [score(f, want), i, f] }.sort_by { |s, i, _| [-s, i] }
        best = scored[0][0]
        m = Match.new(foreign, scored[0][2], :ambiguous, best - 1, scored.map(&:last).freeze, scored.count { |s, _, _| s == best })
        warn_once(m) if warn
        m
      end

      # The local path for +foreign+, or nil (see #resolve).
      def [](foreign)
        resolve(foreign).path
      end
      alias find []

      # True while every indexed folder still exists with the same mtime
      # (files added, removed, or renamed change their folder's).
      def fresh?
        @folders.all? { |dir, mtime| (File.stat(dir).mtime.to_r == mtime rescue false) }
      end

      def inspect
        "#<#{self.class.name} #{@root} #{size} files, #{ambiguous.length} shared names>"
      end
      alias to_s inspect

      private

      # The number of parts of +path+ (a local file) matching +want+'s from
      # the end, the name included.
      def score(path, want)
        have = path.split('/')
        n = 0
        n += 1 while n < want.length && n < have.length && self.class.key(have[-1 - n]) == want[-1 - n]
        n
      end

      def warn_once(m)
        first = @warn_lock.synchronize { @warned.key?([m.foreign, m.path]) ? false : (@warned[[m.foreign, m.path]] = true) }
        Kernel.warn("MediaIndex: #{m.message}") if first
      end

      def walk(dir)
        @folders[dir] = File.stat(dir).mtime.to_r
        Dir.children(dir).sort.each do |name|
          next if !@hidden && name.start_with?('.')

          full = File.join(dir, name)
          st = File.lstat(full) rescue next
          if st.directory?
            walk(full)
          elsif st.file? || (st.symlink? && File.file?(full))
            next if @extensions && !@extensions.include?(self.class.key(File.extname(name)))

            @files[self.class.key(name)] << full
          end
        end
      rescue Errno::EACCES, Errno::ENOENT
        nil
      end
    end
  end
end
