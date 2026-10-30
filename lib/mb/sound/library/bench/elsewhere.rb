require 'open3'

module MB
  module Sound
    module Library
      module Bench
        # The child process rendering a job file in another checkout
        # (Bench.render_elsewhere): loads that checkout's mb-sound, then
        # this checkout's Bench (so both sides render the same way), and
        # runs the jobs.
        CHILD = <<~'RUBY'.freeze
          require 'json'
          require 'mb/sound'
          job = JSON.parse(File.read(ARGV[0]))
          lib = MB::Sound::Library
          lib.send(:remove_const, :Bench) if lib.const_defined?(:Bench, false)
          # (fresh: that checkout may be this one, whose parts are loaded)
          mine = File.join(job.fetch('lib'), 'mb/sound/library/bench')
          $LOADED_FEATURES.reject! { |f| f == "#{mine}.rb" || f.start_with?("#{mine}/") }
          load "#{mine}.rb"
          MB::Sound::Library::Bench.run_job_file(ARGV[0])
        RUBY

        module_function

        # This checkout's top directory.
        def checkout_dir = File.expand_path('../../../../..', __dir__)

        # "branch commit" of a checkout, for labels and set metadata.
        def describe_checkout(dir = checkout_dir)
          branch, = Open3.capture2('git', '-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD', err: File::NULL)
          commit, = Open3.capture2('git', '-C', dir, 'rev-parse', '--short=10', 'HEAD', err: File::NULL)
          { branch: branch.strip, commit: commit.strip }
        end

        # The worktree for +ref+: a directory, else the worktree that has
        # branch +ref+ checked out (git worktree list).  Raises with the
        # commands that make one otherwise.
        def worktree_for(ref)
          return File.expand_path(ref) if File.directory?(ref.to_s)
          list, = Open3.capture2('git', '-C', checkout_dir, 'worktree', 'list', '--porcelain', err: File::NULL)
          path = nil
          list.each_line do |l|
            path = l.split(' ', 2)[1].strip if l.start_with?('worktree ')
            return path if l.strip == "branch refs/heads/#{ref}" && File.directory?(path.to_s)
          end
          raise ArgumentError, "no worktree has #{ref} checked out; make one: git worktree add --detach /claude/worktrees/#{ref}-bench #{ref} && " \
            "(cd /claude/worktrees/#{ref}-bench && bundle exec rake compile), then --vs /claude/worktrees/#{ref}-bench"
        end

        # Renders +jobs+ (not the dry ones: the dry material is the same on
        # both sides) in the checkout at +vs+ into +dir+/before, reading
        # the effect materials from +files+.  Returns { item => Measure,
        # or :missing (the other checkout has no such entry or material) }.
        def render_elsewhere(vs, jobs, dir, lufs:, ceiling:, format:, files:, io: $stdout)
          path = worktree_for(vs)
          todo = jobs.select(&:entry)
          job_path = File.join(dir, 'before.jobs.json')
          File.write(job_path, JSON.pretty_generate(
            lib: File.join(checkout_dir, 'lib'), out: File.join(dir, 'before'), lufs: lufs, ceiling: ceiling, format: format, files: files,
            jobs: todo.map { |j| { item: j.item, family: j.entry.family, name: j.entry.name, material: j.material.key, file: j.file } }
          ))
          env = { 'BUNDLE_GEMFILE' => File.join(path, 'Gemfile') }
          cmd = ['bundle', 'exec', 'ruby', '-Ilib', '-e', CHILD, job_path]
          status = nil
          runner = -> {
            Open3.popen2e(env, *cmd, chdir: path) do |_in, out, wait|
              out.each_line { |l| io&.puts "  #{vs}: #{l.chomp}" }
              status = wait.value
            end
          }
          defined?(Bundler) ? Bundler.with_unbundled_env(&runner) : runner.call
          raise "rendering in #{path} failed (#{status})" unless status&.success?
          out = JSON.parse(File.read("#{job_path}.out.json"))
          out.to_h { |item, m| [item, m['missing'] ? :missing : Measure.new(**m.transform_keys(&:to_sym))] }
        end

        # Runs a job file written by #render_elsewhere (in the child):
        # renders each job and writes the measures to <file>.out.json.
        def run_job_file(path)
          job = JSON.parse(File.read(path))
          files = job['files']
          results = {}
          job['jobs'].each do |j|
            entry = Bench.entry(j['family'], j['name'])
            material = entry && Bench.material(entry, j['material'])
            unless material
              results[j['item']] = { missing: true }
              puts "#{j['family']} :#{j['name']} #{j['material']}: not here"
              next
            end
            jb = Job.new(item: j['item'], entry: entry, material: material, file: j['file'])
            m = render_job(jb, job['out'], lufs: job['lufs'], ceiling: job['ceiling'], format: job['format'], files: files)
            results[j['item']] = m.to_h
            puts line(jb, m)
          end
          File.write("#{path}.out.json", JSON.pretty_generate(results))
        end
      end
    end
  end
end
