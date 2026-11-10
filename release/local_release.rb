# A reproducible local release of mb-sound: .gem files for mb-sound, mb-term
# (gems/mb-term), the git-only dependencies at the revisions Gemfile.lock
# pins (mb-math, mb-util), and every other runtime dependency at its locked
# version, in one directory; then an install of them into a fresh GEM_HOME
# with no Bundler and no checkout (`gem install --local`, extensions compiled
# at install), as a musician gets mb-sound.  `rake release:local DIR=...`
# runs both steps, `rake release:smoke DIR=...` the clean-room smoke test
# (release/clean_room_smoke.rb) against the install.  See
# design/notes/release.md.
#
# Building needs the checkout's bundle (it runs under `bundle exec rake`):
# the git dependencies are cloned from Bundler's own checkouts of them (the
# network only when a checkout lacks the pinned commit), and registry gems
# are copied from RubyGems' and Bundler's caches (`gem fetch` only for those
# missing).  Installing never uses the network.
require 'fileutils'
require 'open3'
require 'rbconfig'

module MB
  module Sound
    class LocalRelease
      ROOT = File.expand_path('..', __dir__)

      # Gems built from directories of this repository: name => gemspec path.
      LOCAL_GEMS = {
        'mb-sound' => 'mb-sound.gemspec',
        'mb-term' => 'gems/mb-term/mb-term.gemspec',
      }.freeze

      # Folders whose tracked files ship in the gems (see #check_untracked!).
      SHIPPED = %w[lib bin ext presets matrices sounds gems/mb-term/lib gems/mb-term/ext].freeze

      # Raised when a step fails, with the command's output.
      class Error < RuntimeError; end

      attr_reader :dir, :gem_dir, :gem_home, :room, :home

      # +dir+ holds everything: gems/ (the .gem files), src/ (clones of the
      # git dependencies), gem_home/ (the clean install), home/ (the clean
      # room's HOME, so user data directories start empty), and room/ (an
      # empty working directory).
      def initialize(dir, io: $stdout)
        @dir = File.expand_path(dir)
        @gem_dir = File.join(@dir, 'gems')
        @gem_home = File.join(@dir, 'gem_home')
        @home = File.join(@dir, 'home')
        @room = File.join(@dir, 'room')
        @io = io
      end

      # Builds every .gem file into gems/ (emptied first).  Returns the list
      # of .gem paths.
      def build
        require 'bundler'
        FileUtils.rm_rf(@gem_dir)
        FileUtils.mkdir_p(@gem_dir)

        lock = Bundler::LockfileParser.new(File.read(File.join(ROOT, 'Gemfile.lock')))
        locked = lock.specs.select { |s| s.platform.to_s == 'ruby' || s.platform.to_s == Gem::Platform.local.to_s }
                           .to_h { |s| [s.name, s] }

        check_untracked!
        LOCAL_GEMS.each_value { |gemspec| build_gem(File.join(ROOT, gemspec)) }

        git_names = []
        lock.sources.grep(Bundler::Source::Git).each do |source|
          names = source.specs.map(&:name) & runtime_closure(locked)
          next if names.empty?
          git_names.concat(names)
          src = clone_git(source, names.first)
          names.each { |n| build_gem(Dir[File.join(src, "#{n}.gemspec")].first || raise(Error, "no #{n}.gemspec in #{src}")) }
        end

        (runtime_closure(locked) - LOCAL_GEMS.keys - git_names).each do |name|
          copy_registry_gem(locked.fetch(name))
        end

        gems = Dir[File.join(@gem_dir, '*.gem')].sort
        @io.puts "release: #{gems.length} gems in #{@gem_dir}"
        gems
      end

      # Installs mb-sound from gems/ into a fresh gem_home/ (emptied first)
      # with `gem install --local`, outside any bundle, compiling the C
      # extensions.  Returns the installed mb-sound's directory.
      def install
        FileUtils.rm_rf([@gem_home, @home, @room])
        FileUtils.mkdir_p([@gem_home, @home, @room])
        gem = Dir[File.join(@gem_dir, 'mb-sound-*.gem')].first || raise(Error, "no mb-sound gem in #{@gem_dir} (rake release:local)")
        @io.puts "release: installing #{File.basename(gem)} into #{@gem_home} (compiling the C extensions)"
        run!(clean_env, 'gem', 'install', '--local', '--no-document', '--install-dir', @gem_home, File.basename(gem), chdir: @gem_dir)
        out = run!(clean_env, 'ruby', '-e', 'print Gem::Specification.find_by_name("mb-sound").gem_dir', chdir: @room)
        @io.puts "release: installed #{out}"
        out
      end

      # The clean room's environment: gem_home and Ruby's own gem directory
      # (Gem.default_dir: the default and bundled gems of a fresh Ruby;
      # GEM_PATH leaves out Bundler's and the user's gem directories), no
      # Bundler or Ruby options from the calling process, a fresh HOME, and
      # OUTPUT_TYPE=null (no sound card needed).  The other variables (PATH,
      # TERM, LANG) pass through, with gem_home/bin first in PATH.
      def clean_env
        env = ENV.to_h.reject { |k, _| k.start_with?('BUNDLE', 'GEM_', 'RUBY') || k.start_with?('MB_SOUND') || %w[RUBYOPT RUBYLIB XDG_DATA_HOME XDG_CONFIG_HOME].include?(k) }
        env.merge(
          'GEM_HOME' => @gem_home, 'GEM_PATH' => [@gem_home, Gem.default_dir].join(File::PATH_SEPARATOR), 'HOME' => @home,
          'PATH' => [File.join(@gem_home, 'bin'), RbConfig::CONFIG['bindir'], ENV['PATH']].join(File::PATH_SEPARATOR),
          'OUTPUT_TYPE' => 'null', 'MAKEFLAGS' => "-j#{[ENV['MAKE_JOBS'].to_i, 1].max}"
        )
      end

      # Runs +cmd+ with +env+ replacing the whole environment; raises Error
      # with its output when it fails.  Returns its standard output.
      def run!(env, *cmd, chdir:)
        out, err, status = Open3.capture3(env, *cmd, chdir: chdir, unsetenv_others: true)
        raise Error, "#{cmd.join(' ')} failed (#{status}):\n#{out}#{err}" unless status.success?
        out
      end

      private

      # The names of mb-sound's runtime dependencies and theirs, from the
      # lockfile, without Ruby's default gems (always present).
      def runtime_closure(locked)
        @closure ||= begin
          spec = Gem::Specification.load(File.join(ROOT, 'mb-sound.gemspec'))
          seen = []
          todo = spec.runtime_dependencies.map(&:name)
          until todo.empty?
            name = todo.shift
            next if seen.include?(name)
            seen << name
            todo.concat(locked[name]&.dependencies&.map(&:name) || local_dependencies(name))
          end
          seen.reject { |n| default_gem?(n) && !locked.key?(n) }
        end
      end

      # Runtime dependency names of a gem built here (mb-term's are its
      # gemspec's: the lockfile lists a path gem's dependencies too, but
      # this keeps the gemspec the source).
      def local_dependencies(name)
        path = LOCAL_GEMS[name]
        path ? Gem::Specification.load(File.join(ROOT, path)).runtime_dependencies.map(&:name) : []
      end

      def default_gem?(name)
        Gem::Specification.default_stubs.any? { |s| s.name == name }
      end

      # The gemspecs list the files git tracks: an untracked file under a
      # shipped folder would be missing from the gem (a new lib/ file the
      # gem then fails to load), so building stops with their names.
      def check_untracked!
        out, status = Open3.capture2('git', '-C', ROOT, 'ls-files', '--others', '--exclude-standard', '--', *SHIPPED)
        raise Error, "git ls-files failed in #{ROOT}" unless status.success?
        return if out.strip.empty?
        raise Error, "untracked files would be left out of the gems (git add or remove them):\n  #{out.lines.map(&:strip).join("\n  ")}"
      end

      # Builds the gemspec at +path+ in its directory, moving the .gem into
      # gems/.
      def build_gem(path)
        dir = File.dirname(path)
        out = run!(build_env, 'gem', 'build', File.basename(path), chdir: dir)
        file = out[/File: (\S+\.gem)/, 1] || raise(Error, "gem build #{path}: no File: line in\n#{out}")
        FileUtils.mv(File.join(dir, file), @gem_dir)
        @io.puts "release: built #{file}"
      end

      # Clones the git source pinned in the lockfile into src/<name> at its
      # revision: from Bundler's checkout when it has the commit, else from
      # the remote.  Returns the clone's directory.
      def clone_git(source, name)
        rev = source.revision || raise(Error, "#{name}: no revision in Gemfile.lock")
        dest = File.join(@dir, 'src', name)
        FileUtils.rm_rf(dest)
        FileUtils.mkdir_p(File.dirname(dest))
        local = Bundler.load.specs[name].first&.full_gem_path rescue nil
        origin = local && File.exist?(File.join(local, '.git')) ? local : source.uri
        run!(build_env, 'git', 'clone', '--quiet', '--no-checkout', origin, dest, chdir: @dir)
        _, status = Open3.capture2e('git', '-C', dest, 'cat-file', '-e', "#{rev}^{commit}")
        unless status.success?
          @io.puts "release: #{name} #{rev[0, 12]} not in #{origin}; cloning #{source.uri}"
          FileUtils.rm_rf(dest)
          run!(build_env, 'git', 'clone', '--quiet', '--no-checkout', source.uri.to_s, dest, chdir: @dir)
        end
        run!(build_env, 'git', '-c', 'advice.detachedHead=false', 'checkout', '--quiet', rev, chdir: dest)
        @io.puts "release: #{name} at #{rev[0, 12]} (#{source.uri})"
        dest
      end

      # Copies the locked version of a registry gem into gems/ from a gem
      # cache, or fetches it.
      def copy_registry_gem(spec)
        file = "#{spec.full_name}.gem"
        caches = (Gem.path + [Gem.default_dir, ENV['GEM_HOME'].to_s]).uniq.map { |p| File.join(p, 'cache') }
        found = caches.map { |c| File.join(c, file) }.find { |f| File.file?(f) }
        if found
          FileUtils.cp(found, @gem_dir)
        else
          @io.puts "release: fetching #{file}"
          run!(build_env, 'gem', 'fetch', spec.name, '-v', spec.version.to_s, chdir: @gem_dir)
        end
      end

      # The calling environment without Bundler's variables, so `gem build`
      # and git run as they would by hand.
      def build_env
        ENV.to_h.reject { |k, _| k.start_with?('BUNDLE') || k == 'RUBYOPT' || k == 'RUBYLIB' }
      end
    end
  end
end
