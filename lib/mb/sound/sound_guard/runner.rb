require 'json'
require 'time'

module MB
  module Sound
    module SoundGuard
      # Renders golden-set pieces as processes, fingerprints them, and checks
      # or approves them (the rake golden:* tasks; design/notes/sound_guards.md).
      #
      # Layout under SoundGuard.golden_dir (not in git):
      #   approved/<name>.flac, approved/<name>.json  the approved render and
      #                                               what made it
      #   runs/<stamp>-<commit>/                      one check or approve run:
      #     <name>.flac, <name>.log, report.txt, results.json, and on
      #     failures bench/ (MP3s) + bench_set.py for the Listening Bench
      class Runner
        Result = Data.define(:piece, :path, :seconds, :error, :fingerprint, :comparison) do
          def ok? = error.nil?
          def status
            return :error unless ok?
            return :unapproved if comparison.nil?
            comparison.pass? ? :pass : :fail
          end
        end

        attr_reader :set, :dir

        # +set+ a GoldenSet; +parallel+ renders at once; +io+ for progress.
        def initialize(set, parallel: Integer(ENV['PARALLEL'] || 2), io: $stdout, golden_dir: SoundGuard.golden_dir(set.root))
          @set = set
          @parallel = [parallel, 1].max
          @io = io
          @golden_dir = golden_dir
          @commit = SoundGuard.commit(set.root)
          @dir = nil
        end

        def approved_dir = File.join(@golden_dir, 'approved')

        # Renders +pieces+ into a new run directory (or reuses the renders in
        # +run_dir+), fingerprints them, and compares them with the committed
        # fingerprints.  Writes report.txt and results.json, plus a Bench set
        # when anything fails.  Returns the Results.
        def check(pieces, run_dir: nil)
          results = render_all(pieces, run_dir: run_dir, kind: 'check').map { |r|
            next r unless r.ok?
            approved = @set.approved_fingerprint(r.piece)
            r.with(comparison: approved && approved.compare(r.fingerprint))
          }
          report(results)
          bench(results.select { |r| r.status == :fail })
          results
        end

        # Renders +pieces+ (or takes their renders from +run_dir+) and makes
        # them the approved versions: fingerprints into golden/fingerprints,
        # renders into approved/.
        def approve(pieces, run_dir: nil)
          FileUtils.mkdir_p(approved_dir)
          FileUtils.mkdir_p(@set.fingerprints_dir)
          results = render_all(pieces, run_dir: run_dir, kind: 'approve')
          results.each do |r|
            unless r.ok?
              @io.puts "golden: #{r.piece.name} NOT approved: #{r.error}"
              next
            end
            r.fingerprint.save(@set.fingerprint_path(r.piece))
            FileUtils.cp(r.path, File.join(approved_dir, "#{r.piece.name}.flac"))
            File.write(File.join(approved_dir, "#{r.piece.name}.json"), JSON.pretty_generate(r.fingerprint[:source]))
            @io.puts "golden: approved #{r.piece.name} (#{r.fingerprint.duration.round(1)} s, #{r.fingerprint[:loudness][:integrated]} LUFS)"
          end
          results
        end

        # Re-extracts the committed fingerprints from the approved renders
        # (after a Fingerprint::FORMAT change), keeping their sources.
        def refingerprint(pieces)
          pieces.each do |piece|
            flac = File.join(approved_dir, "#{piece.name}.flac")
            unless File.exist?(flac)
              @io.puts "golden: no approved render for #{piece.name} (approve it: rake golden:approve[#{piece.name}])"
              next
            end
            meta_path = File.join(approved_dir, "#{piece.name}.json")
            meta = File.exist?(meta_path) ? JSON.parse(File.read(meta_path), symbolize_names: true) : nil
            Fingerprint.extract(flac, name: piece.name, meta: meta).save(@set.fingerprint_path(piece))
            @io.puts "golden: refingerprinted #{piece.name}"
          end
        end

        # Renders and fingerprints +pieces+ into +dir+ with +env+ added to the
        # render processes' environment (calibration perturbations), or
        # fingerprints the renders already there with +reuse+.
        def render(pieces, dir:, env: {}, reuse: false)
          FileUtils.mkdir_p(dir)
          render_all(pieces, run_dir: dir, kind: 'render', env: env, reuse: reuse)
        end

        private

        def new_run_dir(kind)
          stamp = Time.now.utc.strftime('%Y%m%d-%H%M%S')
          base = File.join(@golden_dir, 'runs', "#{stamp}-#{kind}-#{@commit || 'nogit'}")
          dir = base
          n = 1
          dir = "#{base}-#{n += 1}" while File.exist?(dir)
          FileUtils.mkdir_p(dir)
          dir
        end

        # Renders (or reuses) and fingerprints every piece; Results in order.
        def render_all(pieces, run_dir:, kind:, env: {}, reuse: !run_dir.nil?)
          @dir = run_dir ? File.expand_path(run_dir) : new_run_dir(kind)
          @io.puts "golden: #{kind} #{pieces.length} piece#{'s' unless pieces.length == 1} in #{@dir}#{reuse ? ' (reusing renders)' : " (#{@parallel} at a time)"}"
          queue = Queue.new
          pieces.each_with_index { |p, i| queue << [p, i] }
          results = Array.new(pieces.length)
          workers = Array.new([@parallel, pieces.length].min) {
            Thread.new {
              loop {
                job = begin
                  queue.pop(true)
                rescue ThreadError
                  break
                end
                results[job[1]] = render_one(job[0], reuse: reuse, env: env)
              }
            }
          }
          workers.each(&:join)
          results
        end

        def render_one(piece, reuse:, env: {})
          out = File.join(@dir, "#{piece.name}.flac")
          seconds = 0.0
          unless reuse
            log = File.join(@dir, "#{piece.name}.log")
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            pid = Process.spawn(render_env.merge(env), *piece.command(out, root: @set.root), chdir: @set.root, out: log, err: log, in: File::NULL)
            _, status = Process.wait2(pid)
            seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            unless status.success? && File.exist?(out)
              tail = File.exist?(log) ? File.readlines(log).last(5).join.strip : ''
              return Result.new(piece, out, seconds, "render failed (#{status}): #{tail}", nil, nil)
            end
          end
          return Result.new(piece, out, seconds, "no render #{out}", nil, nil) unless File.exist?(out)

          meta = { command: piece.shell_command, commit: @commit, rendered: File.mtime(out).utc.iso8601, render_seconds: seconds.round(1) }
          fp = Fingerprint.extract(out, name: piece.name, meta: meta)
          @io.puts format('golden: %-14s rendered in %5.1f s (%.1f s of audio)', piece.name, seconds, fp.duration)
          Result.new(piece, out, seconds, nil, fp, nil)
        rescue => e
          Result.new(piece, out, seconds, "#{e.class}: #{e.message}", nil, nil)
        end

        # Renders get the realtime-free defaults of a script render; no
        # terminal colors.
        def render_env
          { 'NO_COLOR' => '1', 'OUTPUT_TYPE' => 'null' }
        end

        def report(results)
          lines = ["Golden set check at #{@commit} (#{Time.now.utc.iso8601}), renders in #{@dir}", '']
          results.each do |r|
            case r.status
            when :error
              lines << "#{r.piece.name}: ERROR #{r.error}"
            when :unapproved
              lines << "#{r.piece.name}: UNAPPROVED (no golden/fingerprints/#{r.piece.name}.json; rake golden:approve[#{r.piece.name}])"
            else
              c = r.comparison
              lines << format('%s: %s (worst %.2f of its limit)', r.piece.name, r.status.to_s.upcase, c.worst_ratio)
              lines << c.to_s unless c.pass?
            end
          end
          counts = results.group_by(&:status).transform_values(&:length)
          lines << ''
          lines << counts.map { |k, v| "#{v} #{k}" }.join(', ')
          text = lines.join("\n") + "\n"
          File.write(File.join(@dir, 'report.txt'), text)
          File.write(File.join(@dir, 'results.json'), JSON.pretty_generate(results.map { |r|
            { name: r.piece.name, status: r.status, error: r.error, render_seconds: r.seconds.round(1), distances: r.comparison&.to_h }
          }))
          @io.puts text
        end

        # A Listening Bench set (approved vs new) for the failed results.
        def bench(failed)
          return if failed.empty?
          bdir = File.join(@dir, 'bench')
          FileUtils.mkdir_p(bdir)
          set_id = "golden-#{Time.now.utc.strftime('%Y-%m-%d')}-#{@commit}"
          items = failed.map { |r|
            name = r.piece.name
            approved_flac = File.join(approved_dir, "#{name}.flac")
            meta_path = File.join(approved_dir, "#{name}.json")
            meta = File.exist?(meta_path) ? JSON.parse(File.read(meta_path), symbolize_names: true) : {}
            variants = []
            if File.exist?(approved_flac)
              mp3(approved_flac, File.join(bdir, "#{name}_approved.mp3"))
              variants << { label: "approved (#{meta[:commit]})", role: 'before', file: "audio/#{set_id}/#{name}_approved.mp3",
                            code: "git checkout #{meta[:commit]} && #{r.piece.shell_command}" }
            end
            mp3(r.path, File.join(bdir, "#{name}_new.mp3"))
            variants << { label: "new (#{@commit})", role: 'after', file: "audio/#{set_id}/#{name}_new.mp3",
                          code: "git checkout #{@commit} && #{r.piece.shell_command}" }
            c = r.comparison
            note = "#{r.piece.genre}: #{r.piece.covers}. Over the limit: " +
              c.failures.map { |k| format('%s %.2f %s (limit %g)', k, c.distances[k], Comparison::UNITS[k], c.thresholds[k]) }.join('; ') +
              ". Levels as rendered (not loudness-matched). Approve the new one: rake golden:approve[#{name}] RUN=#{@dir}"
            { id: "golden.#{name}", title: "#{name} (#{r.piece.genre})", note: note, variants: variants }
          }
          set = { id: set_id, title: "Golden set: #{failed.length} changed at #{@commit}", date: Time.now.utc.strftime('%Y-%m-%d'),
                  summary: 'Golden-set pieces whose fingerprints moved past their thresholds (design/notes/sound_guards.md): the approved render and the new one. Your verdict decides: "after" = re-approve.',
                  groups: [{ id: 'golden', title: 'Changed pieces', items: items }] }
          py = +"# Listening Bench set from rake golden:check (#{@commit}); audio in #{bdir}\n"
          py << "# (publish as audio/#{set_id}/<file>).\n"
          py << "import json\nsets.append(json.loads(#{JSON.generate(JSON.generate(set))}))\n"
          File.write(File.join(@dir, 'bench_set.py'), py)
          @io.puts "golden: Bench set for #{failed.length} changed piece#{'s' unless failed.length == 1}: #{File.join(@dir, 'bench_set.py')}"
        end

        def mp3(src, dest)
          system('ffmpeg', '-loglevel', 'error', '-y', '-i', src, '-c:a', 'libmp3lame', '-b:a', '320k', dest) ||
            @io.puts("golden: ffmpeg could not make #{dest}")
        end
      end
    end
  end
end
