# Runs memcheck spec files in several Valgrind processes at once (`rake
# memcheck`, `rake memcheck:changed`; memcheck-par-1, 2026-10-30: the
# maintainer chose parallel Valgrind processes over a sanitizer lane).
#
# Valgrind runs a process's threads one at a time, so one rspec under it
# uses one core: the full list took 53 min in one process on 2026-10-16.
# Here the files are split into groups of about equal expected time
# (longest first into the least loaded group, like spec/parallel_specs.rb),
# each group runs as its own `valgrind ruby rspec` with its own
# ruby_memcheck Configuration (temp dir for the per-PID XML files and its
# loaded-features file), and each group's XML is checked by its own
# ruby_memcheck reporter after every process has ended.  Logs go to
# tmp/memcheck/N.log (rspec's progress and summary) and N.err (stderr),
# per-example JSON to tmp/memcheck/N.json, merged into
# tmp/memcheck_times.json.
#
# Expected times come from the main checkout's tmp/memcheck_file_times.json
# (shared by every worktree, like the full-run stamp; seconds and example
# counts per file under Valgrind, plus the per-process startup), updated
# after every run; files without one are estimated from their native times
# (tmp/spec_file_times.json) times Valgrind's measured slowdown, else from
# their size.
#
# The number of processes: MEMCHECK_PARALLEL when set, else the fewest that
# come within 10% of the shortest expected run with at most half the CPUs
# and at most one process per MEMORY_PER_PROCESS of available memory (each
# also pays Ruby's and mb-sound's startup under Valgrind, STARTUP_SECONDS
# until measured).  A status line every minute shows examples done and
# memory; every process's peak memory (its whole process tree, sampled
# every 2 s from /proc) is printed when it ends.
#
# Plain Ruby: the partition and count logic loads without ruby_memcheck (the
# specs in memcheck_parallel_spec.rb); .run needs it.
require 'etc'
require 'fileutils'
require 'json'
require 'shellwords'
require 'stringio'
require 'time'

module MemcheckParallel
  ROOT = File.expand_path('../..', __dir__)
  OUT_DIR = File.join(ROOT, 'tmp', 'memcheck')
  # The merged per-example times of the last run (rspec's JSON format)
  TIMES_PATH = File.join(ROOT, 'tmp', 'memcheck_times.json')
  TABLE_NAME = 'memcheck_file_times.json'

  # Each process may take this much MemAvailable: Valgrind rspec process
  # trees peaked at 0.9-1.3 GB on 2026-10-30 (Mac container; table in
  # design/notes/c_extensions.md), one at 3.3 GB on 2026-10-09.
  MEMORY_PER_PROCESS = 2.5 * 1024**3

  # Seconds a Valgrind process spends outside examples (Ruby, mb-sound,
  # and the spec files loading, at_exit leak checks), until the table has
  # a measured value (55-65 s on 2026-10-30)
  STARTUP_SECONDS = 60.0

  # Valgrind's slowdown over native rspec for files with no memcheck time,
  # until the table's files give a median
  SLOWDOWN = 30.0

  # The fewest processes whose expected run is within this factor of the
  # best one
  GOOD_ENOUGH = 1.1

  # A process failed, or Valgrind reported errors
  class Failed < StandardError; end

  Group = Struct.new(:index, :files, :expected, :examples, :config, :pid, :log, :err, :json,
                     :started, :finished, :status, :peak_rss, keyword_init: true)

  module_function

  # The main checkout's tmp/ (shared by every worktree), as for the
  # full-run stamp.
  def shared_tmp
    common = IO.popen(['git', '-C', ROOT, 'rev-parse', '--path-format=absolute', '--git-common-dir'], err: File::NULL, &:read).strip
    common.empty? ? File.join(ROOT, 'tmp') : File.join(File.dirname(common), 'tmp')
  end

  def table_path
    File.join(shared_tmp, TABLE_NAME)
  end

  # Expands globs (relative to ROOT) into sorted unique files.
  def expand(patterns)
    Array(patterns).flat_map { |p| Dir.glob(p.sub(%r{\A\./}, ''), base: ROOT) }.uniq.sort
  end

  # Per-file seconds and example counts from rspec JSON (the format of
  # tmp/memcheck_times.json): { 'path' => { 'seconds' =>, 'examples' => } }.
  def file_times_from_json(json)
    json.fetch('examples', []).each_with_object({}) { |e, h|
      f = e['file_path'].to_s.sub(%r{\A\./}, '')
      h[f] ||= { 'seconds' => 0.0, 'examples' => 0 }
      h[f]['seconds'] += e['run_time'].to_f
      h[f]['examples'] += 1
    }
  end

  # The shared table ({ 'files' => {...}, 'startup' => s }), seeded when
  # it doesn't exist yet from the tmp/memcheck_times.json files of the
  # main checkout and this worktree (older runs first, each file's latest
  # time kept: a selective run's file knows only its own files).
  def load_table(path = table_path)
    return JSON.parse(File.read(path)) if File.file?(path)

    seeds = [File.join(shared_tmp, 'memcheck_times.json'), TIMES_PATH].uniq.select { |f| File.file?(f) }
    files = seeds.sort_by { |f| File.mtime(f) }.each_with_object({}) do |f, h|
      h.merge!(file_times_from_json(JSON.parse(File.read(f))))
    rescue JSON::ParserError
      next
    end
    { 'files' => files }
  rescue JSON::ParserError
    { 'files' => {} }
  end

  # Merges +files+ (from #file_times_from_json) and a measured +startup+
  # into the table at +path+ (written whole through a rename, so readers
  # never see half a file).
  def update_table(files, startup: nil, path: table_path)
    table = load_table(path)
    now = Time.now.utc.iso8601
    files.each { |f, v| table['files'][f] = v.merge('date' => now) }
    table['startup'] = startup.round(1) if startup
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.#{Process.pid}"
    File.write(tmp, JSON.pretty_generate(table) + "\n")
    File.rename(tmp, path)
    table
  end

  # Native rspec seconds per file (spec/parallel_specs.rb's table)
  def native_times
    [File.join(ROOT, 'tmp', 'spec_file_times.json'), File.join(shared_tmp, 'spec_file_times.json')].each do |f|
      return JSON.parse(File.read(f)) if File.file?(f)
    rescue JSON::ParserError
      next
    end
    {}
  end

  # A lambda giving each file's expected seconds under Valgrind.
  def estimator(table = load_table, native = native_times)
    known = table.fetch('files', {})
    ratios = known.filter_map { |f, v| v['seconds'] / native[f] if native[f].to_f > 0.05 }.sort
    slowdown = ratios.empty? ? SLOWDOWN : ratios[ratios.length / 2]
    lambda { |f|
      next known[f]['seconds'] if known[f]
      next native[f] * slowdown if native[f]

      size = File.size?(File.join(ROOT, f)) || 3000
      size / 3000.0 * slowdown
    }
  end

  # Splits +files+ into at most +count+ groups of about equal expected time
  # (longest first into the least loaded group).  Returns [[files, seconds],
  # ...] without empty groups.
  def partition(files, count, weight)
    groups = Array.new(count) { [] }
    loads = Array.new(count, 0.0)
    files.sort_by { |f| [-weight.(f), f] }.each do |f|
      i = loads.each_with_index.min_by { |l, j| [l, j] }.last
      groups[i] << f
      loads[i] += weight.(f)
    end
    groups.zip(loads).reject { |g, _| g.empty? }
  end

  # Expected wall seconds with +count+ processes: the longest group plus
  # the startup every process pays.
  def expected_seconds(files, count, weight, startup)
    partition(files, count, weight).map(&:last).max.to_f + startup
  end

  # Bytes of available memory (Linux MemAvailable), or nil
  def available_memory
    kb = File.read('/proc/meminfo')[/^MemAvailable:\s+(\d+)/, 1] if File.readable?('/proc/meminfo')
    kb && kb.to_i * 1024
  end

  # The number of Valgrind processes for +files+ and why: MEMCHECK_PARALLEL,
  # else the fewest within GOOD_ENOUGH of the best expected time, at most
  # half the CPUs, one per MEMORY_PER_PROCESS of available memory, and the
  # number of files.  Returns [count, reason].
  def default_count(files, weight, startup:, env: ENV, cpus: Etc.nprocessors, memory: available_memory)
    return [[Integer(env['MEMCHECK_PARALLEL']), 1].max, 'MEMCHECK_PARALLEL'] if env['MEMCHECK_PARALLEL'] && !env['MEMCHECK_PARALLEL'].empty?

    by_cpu = [cpus / 2, 1].max
    by_ram = memory ? [(memory / MEMORY_PER_PROCESS).floor, 1].max : nil
    limit = [by_cpu, by_ram, files.length].compact.min
    limit = 1 if limit < 1
    times = (1..limit).map { |n| expected_seconds(files, n, weight, startup) }
    best = times.min
    count = (1..limit).find { |n| times[n - 1] <= best * GOOD_ENOUGH }
    ram = memory ? format('%.1f GB available -> at most %d', memory / 1024.0**3, by_ram) : 'memory unknown'
    reason = format('expected %.1f min (%.1f in one process); at most %d: half of %d CPUs, %s, %d files',
                    times[count - 1] / 60, times[0] / 60, limit, cpus, ram, files.length)
    [count, reason]
  end

  # --- Process trees and memory ---------------------------------------

  # { pid => [ppid, rss_bytes] } for every process
  def process_table
    page = 4096
    Dir.glob('/proc/[0-9]*').each_with_object({}) do |dir, h|
      stat = File.read("#{dir}/stat")
      ppid = stat[(stat.rindex(')') + 2)..].split[1].to_i
      rss = File.read("#{dir}/statm").split[1].to_i * page
      h[File.basename(dir).to_i] = [ppid, rss]
    rescue SystemCallError
      next
    end
  end

  # Bytes resident in +pid+ and its descendants in +table+
  def tree_rss(pid, table)
    children = Hash.new { |h, k| h[k] = [] }
    table.each { |p, (pp, _)| children[pp] << p }
    stack = [pid]
    total = 0
    until stack.empty?
      p = stack.pop
      total += table[p]&.last.to_i
      stack.concat(children[p])
    end
    total
  end

  def gb(bytes)
    format('%.2f GB', bytes / 1024.0**3)
  end

  # Examples finished so far in a progress-format log
  def progress_count(log)
    text = File.file?(log) ? File.read(log) : ''
    text = text.split(/\n(?:Finished in|Pending:|Failures:)/, 2).first.to_s
    text.count('.F*')
  end

  # --- Running ---------------------------------------------------------

  # Runs +patterns+ (globs or files) under Valgrind in parallel.
  # +config_for+ is called with an output IO for each process and returns
  # its RubyMemcheck::Configuration; +rspec_opts+ are extra rspec options.
  # Prints progress, per-process results, Valgrind errors, and a summary;
  # raises Failed when a process failed or Valgrind reported errors.
  # Returns the merged rspec JSON.  +out_dir+, +times_path+, and
  # +table_path+ are for specs.
  def run(patterns, config_for:, rspec_opts: [], env: {}, count: nil, out: $stdout,
          out_dir: OUT_DIR, times_path: TIMES_PATH, table_path: self.table_path)
    require 'ruby_memcheck'

    files = expand(patterns)
    raise Failed, 'memcheck: no spec files match' if files.empty?

    table = load_table(table_path)
    weight = estimator(table)
    startup = (table['startup'] || STARTUP_SECONDS).to_f
    count, why = count ? [count, 'given'] : default_count(files, weight, startup: startup)
    parts = partition(files, count, weight)
    out.puts format('memcheck: %d spec files in %d Valgrind processes (%s)', files.length, parts.length, why)

    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)
    known = table.fetch('files', {})
    groups = parts.each_with_index.map { |(group_files, seconds), i|
      Group.new(
        index: i + 1, files: group_files, expected: seconds,
        examples: group_files.sum { |f| known.dig(f, 'examples').to_i },
        log: File.join(out_dir, "#{i + 1}.log"), err: File.join(out_dir, "#{i + 1}.err"),
        json: File.join(out_dir, "#{i + 1}.json"), peak_rss: 0
      )
    }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      groups.each { |g| spawn_group(g, config_for, rspec_opts, env) }
      wait_all(groups, started, out)
    # Any exception, Ctrl-C included, stops every Valgrind process group
    rescue Exception # rubocop:disable Lint/RescueException
      groups.each { |g| Process.kill('TERM', -g.pid) if g.pid && !g.status rescue nil }
      groups.each { |g| Process.wait(g.pid) if g.pid && !g.status rescue nil }
      groups.each { |g| FileUtils.rm_rf(g.config.temp_dir) if g.config }
      raise
    end
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    errors = check_valgrind(groups, out)
    merged = merge_json(groups, wall)
    FileUtils.mkdir_p(File.dirname(times_path))
    File.write(times_path, JSON.generate(merged))
    record_times(groups, merged, table_path)
    summarize(groups, merged, wall, errors, out, times_path)
    merged
  end

  def spawn_group(g, config_for, rspec_opts, env)
    io = StringIO.new
    g.config = config_for.call(io)
    # rspec as RubyMemcheck::RSpec::RakeTask runs it (rspec-core and
    # rspec-support on the load path, then rspec's exe), without defining a
    # rake task (Rake's options are an OpenStruct: a :performance warning)
    gem_dir = ->(n) { (Gem.loaded_specs[n] || Gem::Specification.find_by_name(n)).full_gem_path }
    core = gem_dir.('rspec-core')
    load_path = %w[rspec-core rspec-support].map { |n| File.join(gem_dir.(n), 'lib') }
    args = [
      "-I#{load_path.map { |p| Shellwords.escape(p) }.join(File::PATH_SEPARATOR)}",
      Shellwords.escape(File.join(core, 'exe', 'rspec')),
      *g.files.map { |f| Shellwords.escape(f) },
      *['--format', 'progress', '--format', 'json', '--out', g.json, *rspec_opts].map { |o| Shellwords.escape(o) },
    ]
    command = g.config.command(args)

    process_env = env.merge(
      'RUBY_MEMCHECK_LOADED_FEATURES_FILE' => File.expand_path(g.config.loaded_features_file),
      'RUBY_MEMCHECK_RUNNING' => '1',
      'RUBY_FREE_AT_EXIT' => '1',
    )
    g.started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    g.pid = Process.spawn(process_env, command, out: g.log, err: g.err, chdir: ROOT, pgroup: true)
  end

  # Waits for every group, sampling memory every 2 s and printing a status
  # line every minute and a line as each process ends.
  def wait_all(groups, started, out)
    last_status = started
    until groups.all?(&:status)
      table = process_table
      groups.each { |g| g.peak_rss = [g.peak_rss, tree_rss(g.pid, table)].max unless g.status }
      groups.each do |g|
        next if g.status

        pid, status = Process.wait2(g.pid, Process::WNOHANG)
        next unless pid

        g.status = status
        g.finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out.puts format('memcheck [%d/%d]: %s in %.1f min (expected %.1f), peak %s, %d files%s',
                        g.index, groups.length, status.success? ? 'passed' : "FAILED (#{status.exitstatus || status})",
                        (g.finished - g.started) / 60, g.expected / 60, gb(g.peak_rss), g.files.length,
                        status.success? ? '' : ", see #{g.log}")
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - last_status >= 60 && !groups.all?(&:status)
        last_status = now
        running = groups.reject(&:status)
        done = groups.sum { |g| progress_count(g.log) }
        total = groups.sum(&:examples)
        rss = running.sum { |g| tree_rss(g.pid, table) }
        out.puts format('memcheck: %.1f min, %d%s examples, %d of %d processes running, %s resident',
                        (now - started) / 60, done, total > 0 ? "/~#{total}" : '', running.length, groups.length, gb(rss))
      end
      sleep 2 unless groups.all?(&:status)
    end
  end

  # Each group's Valgrind XML through its own reporter; returns the number
  # of groups with errors (printed with the group's files).
  def check_valgrind(groups, out)
    groups.count do |g|
      reporter = RubyMemcheck::TestTaskReporter.new(g.config)
      begin
        reporter.report_valgrind_errors
        false
      rescue RuntimeError => e
        raise unless e.message == RubyMemcheck::TestTaskReporter::VALGRIND_REPORT_MSG

        out.puts "memcheck [#{g.index}/#{groups.length}]: Valgrind errors in a process running #{g.files.join(' ')}:"
        out.puts g.config.output_io.string
        true
      ensure
        FileUtils.rm_rf(g.config.temp_dir)
      end
    end
  end

  # The groups' rspec JSON as one document (examples together, counts
  # summed, the duration the run's wall time), with each process's files,
  # times, and peak memory under 'processes'.
  def merge_json(groups, wall)
    docs = groups.map { |g| File.file?(g.json) ? (JSON.parse(File.read(g.json)) rescue {}) : {} }
    counts = %w[example_count failure_count pending_count errors_outside_of_examples_count]
    summary = counts.to_h { |k| [k, docs.sum { |d| d.dig('summary', k).to_i }] }
    {
      'version' => docs.map { |d| d['version'] }.compact.first,
      'examples' => docs.flat_map { |d| d['examples'] || [] },
      'summary' => summary.merge('duration' => wall),
      'summary_line' => format('%d examples, %d failures, %d pending', summary['example_count'], summary['failure_count'], summary['pending_count']),
      'processes' => groups.zip(docs).map { |g, d|
        {
          'files' => g.files, 'expected' => g.expected.round(1),
          'seconds' => g.finished && (g.finished - g.started).round(1),
          'examples_seconds' => (d['examples'] || []).sum { |e| e['run_time'].to_f }.round(1),
          'peak_rss' => g.peak_rss, 'exit' => g.status&.exitstatus,
        }
      },
    }
  end

  # Updates the shared table with this run's file times and the median
  # process startup (wall time outside examples); only for processes that
  # passed, since a failed file's time says little.
  def record_times(groups, merged, path)
    passed = merged['processes'].select { |p| p['exit'] == 0 && p['seconds'] }
    files = file_times_from_json('examples' => merged['examples'].select { |e|
      passed.any? { |p| p['files'].include?(e['file_path'].to_s.sub(%r{\A\./}, '')) }
    })
    overheads = passed.map { |p| p['seconds'] - p['examples_seconds'] }.sort
    update_table(files, startup: overheads.empty? ? nil : overheads[overheads.length / 2], path: path)
  rescue SystemCallError => e
    warn "memcheck: couldn't record file times in #{path}: #{e.message}"
  end

  def summarize(groups, merged, wall, errors, out, times_path)
    slowest = merged['examples'].group_by { |e| e['file_path'].to_s.sub(%r{\A\./}, '') }
                                .map { |f, es| [es.sum { |e| e['run_time'].to_f }, f] }.max_by(5, &:first)
    out.puts 'memcheck: slowest files: ' + slowest.map { |s, f| format('%s %.1f min', File.basename(f), s / 60) }.join(', ')
    out.puts format('memcheck: processes took %s min; peak %s (largest process), merged times in %s',
                    groups.map { |g| g.finished ? format('%.1f', (g.finished - g.started) / 60) : '?' }.join('/'),
                    gb(groups.map(&:peak_rss).max.to_i), times_path.delete_prefix("#{ROOT}/"))
    failed = groups.reject { |g| g.status&.success? }
    failed.each do |g|
      out.puts "memcheck [#{g.index}/#{groups.length}] rspec output (#{g.log}):"
      out.puts File.read(g.log).split(/\n(?=Failures:)/, 2).last.to_s.lines.last(60).join
    end
    if failed.empty? && errors.zero?
      out.puts format('memcheck: %d spec files clean in %.1f min (%s)', groups.sum { |g| g.files.length }, wall / 60, merged['summary_line'])
    else
      raise Failed, format('memcheck: %d of %d processes failed, %d with Valgrind errors (%.1f min)', failed.length, groups.length, errors, wall / 60)
    end
  end
end
