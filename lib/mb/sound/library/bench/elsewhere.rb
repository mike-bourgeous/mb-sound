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
          raise Error, "no worktree has #{ref} checked out; make one: git worktree add --detach /claude/worktrees/#{ref}-bench #{ref} && " \
            "(cd /claude/worktrees/#{ref}-bench && bundle exec rake compile), then --vs /claude/worktrees/#{ref}-bench"
        end

        # Renders +jobs+ (not the dry ones: the dry material is the same on
        # both sides) in the checkout at +vs+, unmatched, as float WAVs in
        # +dir+/before/raw, reading the effect materials from +files+
        # (Bench.run matches them with this side's renders: one loudness
        # for the set).  Returns { item => Raw (its data read back), or
        # :missing (the other checkout has no such entry or material) }.
        def render_elsewhere(vs, jobs, dir, ceiling:, files:, io: $stdout)
          path = worktree_for(vs)
          todo = jobs.select(&:entry)
          job_path = File.join(dir, 'before.jobs.json')
          File.write(job_path, JSON.pretty_generate(
            lib: File.join(checkout_dir, 'lib'), out: File.join(dir, 'before', 'raw'), ceiling: ceiling, files: files,
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
          out.to_h { |item, r| [item, r['missing'] ? :missing : raw_from(r, File.join(dir, 'before', 'raw'))] }
        end

        # The Raw a job file's result +r+ describes, its data read from the
        # float WAV in +raw_dir+.
        def raw_from(r, raw_dir)
          fields = r.transform_keys(&:to_sym).slice(:cut, :render_seconds, :integrated, :true_peak, :silent, :error, :frames)
          wav = r['wav'] && File.join(raw_dir, r['wav'])
          data = wav && File.file?(wav) ? MB::Sound.read(wav).map { |c| Numo::SFloat.cast(c) } : nil
          Raw.new(data: data, **fields)
        end

        # Runs a job file written by #render_elsewhere (in the child):
        # renders each job unmatched into the job file's +out+ directory
        # (float WAVs) and writes their loudness to <file>.out.json.
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
            r = render_raw(jb, files: files)
            res = { cut: r.cut, render_seconds: r.render_seconds.round(3), integrated: r.integrated, true_peak: r.true_peak, silent: r.silent, error: r.error, frames: r.frames }
            if r.data && r.usable?
              res[:wav] = "#{jb.file}.wav"
              out = File.join(job['out'], res[:wav])
              FileUtils.mkdir_p(File.dirname(out))
              MB::Sound.write(out, r.data, sample_rate: 48000, overwrite: true)
            end
            results[j['item']] = res
            puts format('%-34s %-10s %s', entry.head_path, material.key, r.error ? "failed: #{r.error}" : r.usable? ? format('%.1f LUFS %.1f dBTP as rendered, %.1f s', r.integrated, r.true_peak, r.render_seconds) : 'silent')
          end
          File.write("#{path}.out.json", JSON.pretty_generate(results))
        end
      end
    end
  end
end
