module MB
  module Sound
    module UI
      # Notes file system calls made from chosen threads (the painter, the
      # input thread, the pty reader) while it watches: live paths must not
      # read files (on the Linux desktop /app is sshfs, so every stat is a
      # network round trip).  It wraps the Ruby entry points (File, IO, and
      # Dir class methods that touch the file system) by prepending a module
      # once, the first time it starts; while nothing watches, each wrapped
      # call costs one check of a module variable.  It cannot see calls made
      # inside C extensions or by Ruby's own C code (require's load path
      # scans, File#read on an IO already open): `strace -f -e trace=file`
      # finds those where it is installed.  For bin/ui_bench.rb's hunt and
      # the file access guard spec (ui-perf-1).
      #
      #     FileWatch.watch([tiles.thread]) { sleep 2 }  # => [[:stat, "/app/x", "pane.rb:12"], ...]
      module FileWatch
        # The class methods watched, by receiver (File.read and the other
        # IO class methods File inherits are caught by IO's wrappers).
        METHODS = {
          File => %i[open stat lstat exist? file? directory? mtime size size? zero? readable? realpath new],
          IO => %i[read readlines foreach binread write sysopen],
          Dir => %i[glob [] children entries each_child exist? empty? new open],
        }.freeze

        # A module of wrappers for +names+ (prepended to a receiver's
        # singleton class).
        def self.hooks(names)
          Module.new do
            names.each do |name|
              define_method(name) do |*args, **opts, &block|
                FileWatch.note(name, args.first) if FileWatch.active
                super(*args, **opts, &block)
              end
            end
          end
        end

        class << self
          # Truthy while watching (read by the wrappers).
          attr_reader :active
        end

        @active = nil
        @lock = Mutex.new
        @calls = []
        @threads = nil
        @installed = false

        # Watches +threads+ (Thread objects) while the block runs; returns
        # the calls they made: [method, path (String or nil), caller
        # location outside this file].
        def self.watch(threads)
          start(threads)
          yield
          stop
        end

        def self.start(threads)
          install
          @lock.synchronize do
            @calls = []
            @threads = threads.compact
            @active = true
          end
        end

        # Ends watching; returns the calls.
        def self.stop
          @lock.synchronize do
            @active = nil
            c = @calls
            @calls = []
            c
          end
        end

        def self.note(name, arg)
          t = Thread.current
          return unless @threads&.include?(t)
          loc = caller_locations(2, 6).find { |l| !l.path.end_with?('file_watch.rb') }
          path = arg.is_a?(String) ? arg : (arg.respond_to?(:to_path) ? arg.to_path : nil)
          @lock.synchronize { @calls << [name, path, loc && "#{loc.path.sub(%r{.*/(lib|gems|bin)/}, '\1/')}:#{loc.lineno}", t.name] }
        end

        def self.install
          return if @installed
          METHODS.each { |recv, names| recv.singleton_class.prepend(hooks(names)) }
          @installed = true
        end
      end
    end
  end
end
