# Runs the spec suite in several rspec processes (rake spec:parallel), with a
# per-file slowness report so slow specs stay visible instead of hidden by
# the parallelism (the maintainer prefers fixing slow specs; 2026-10-10).
#
# Files are split by their last measured times (tmp/spec_file_times.json,
# written after every parallel run; file sizes stand in for files without
# a time), longest first into the least loaded process.  Each process
# writes progress to tmp/parallel/N.log and per-example JSON to
# tmp/parallel/N.json.  Spec processes already work side by side (per-process
# temp dirs and coverage files; JACK specs take turns through a lock file).
require 'json'
require 'fileutils'

module ParallelSpecs
  ROOT = File.expand_path('..', __dir__)
  OUT_DIR = File.join(ROOT, 'tmp', 'parallel')
  TIMES_PATH = File.join(ROOT, 'tmp', 'spec_file_times.json')

  # Files slower than this (seconds) or examples slower than SLOW_EXAMPLE
  # are listed as slow after every run.
  SLOW_FILE = 8.0
  SLOW_EXAMPLE = 2.0

  module_function

  def spec_files(patterns = nil)
    patterns = ['spec/**/*_spec.rb'] if patterns.nil? || patterns.empty?
    Dir.chdir(ROOT) { patterns.flat_map { |p| File.directory?(p) ? Dir["#{p}/**/*_spec.rb"] : Dir[p] }.uniq.sort }
  end

  def known_times(path = TIMES_PATH)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  rescue JSON::ParserError
    {}
  end

  # Splits +files+ into +count+ groups of about equal expected time.
  def partition(files, count)
    times = known_times
    # Unmeasured files: about 1 s per 3 KB of spec (a rough fit)
    weight = ->(f) { times[f] || File.size(File.join(ROOT, f)) / 3000.0 }
    groups = Array.new(count) { [] }
    loads = Array.new(count, 0.0)
    files.sort_by { |f| -weight.(f) }.each do |f|
      i = loads.each_with_index.min_by(&:first).last
      groups[i] << f
      loads[i] += weight.(f)
    end
    groups.zip(loads).reject { |g, _| g.empty? }
  end

  # Runs the groups, returns true if every process passed.
  def run(count: 4, patterns: nil, extra_args: [])
    files = spec_files(patterns)
    groups = partition(files, count)
    FileUtils.rm_rf(OUT_DIR)
    FileUtils.mkdir_p(OUT_DIR)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "spec:parallel: #{files.length} files in #{groups.length} processes (expected #{groups.map { |_, l| l.round }.join(', ')} s; logs in #{OUT_DIR.delete_prefix("#{ROOT}/")})"
    pids = groups.each_with_index.map do |(group, _), i|
      log = File.join(OUT_DIR, "#{i}.log")
      json = File.join(OUT_DIR, "#{i}.json")
      Process.spawn('bundle', 'exec', 'rspec', '--format', 'progress', '--format', 'json', '--out', json, *extra_args, *group,
                    out: log, err: [:child, :out], chdir: ROOT)
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    report(groups.map(&:first), statuses, wall)
  end

  # Prints the summary of a run of +groups+ (lists of files), whose
  # processes ended with +statuses+ (Process::Status), and writes the
  # measured file times.  A process without a readable JSON report crashed
  # (e.g. a segfault in a C library): it's listed with its signal, files, and
  # log, and the other processes' times are still written.  Returns true if
  # every process passed.
  def report(groups, statuses, wall, out_dir: OUT_DIR, times_path: TIMES_PATH)
    examples = []
    crashed = []
    groups.each_index do |i|
      json = File.join(out_dir, "#{i}.json")
      begin
        examples.concat(JSON.parse(File.read(json)).fetch('examples'))
      rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError
        crashed << i
      end
    end

    file_times = Hash.new(0.0)
    examples.each { |e| file_times[e['file_path'].delete_prefix('./')] += e['run_time'] }
    File.write(times_path, JSON.pretty_generate(known_times(times_path).merge(file_times.transform_values { |t| t.round(3) })) + "\n")

    failed = examples.select { |e| e['status'] == 'failed' }
    pending = examples.count { |e| e['status'] == 'pending' }
    puts format('spec:parallel: %d examples, %d failures, %d pending in %.1f s wall (%.1f s of examples)',
                examples.length, failed.length, pending, wall, file_times.values.sum)

    puts 'Slowest files:'
    file_times.sort_by { |_, t| -t }.first(10).each { |f, t| puts format('  %6.2f s %s%s', t, f, t > SLOW_FILE ? '  SLOW' : '') }
    slow_examples = examples.select { |e| e['run_time'] > SLOW_EXAMPLE }.sort_by { |e| -e['run_time'] }
    unless slow_examples.empty?
      puts "Examples over #{SLOW_EXAMPLE} s:"
      slow_examples.first(15).each { |e| puts format('  %6.2f s %s:%d %s', e['run_time'], e['file_path'].delete_prefix('./'), e['line_number'], e['full_description'][0, 90]) }
    end

    failed.each { |e| puts "rspec #{e['file_path']}:#{e['line_number']} # #{e['full_description']}" }
    crashed.each { |i| report_crash(i, groups[i], statuses[i], out_dir) }
    bad = statuses.each_with_index.reject { |s, i| s.success? || crashed.include?(i) }
    bad.each { |s, i| puts "spec:parallel: process #{i} exited with #{s.exitstatus} (see #{display_path(File.join(out_dir, "#{i}.log"))})" }
    bad.empty? && crashed.empty?
  end

  # Lists a process that ended without its JSON report.
  def report_crash(index, files, status, out_dir)
    log = File.join(out_dir, "#{index}.log")
    how =
      if status.nil?
        'never reported'
      elsif status.signaled?
        name = Signal.signame(status.termsig) rescue nil
        "was killed by #{name ? "SIG#{name}" : 'signal'} (#{status.termsig})"
      else
        "exited with #{status.exitstatus}"
      end
    bug = File.foreach(log).find { |l| l.include?('[BUG]') } rescue nil
    progress = File.foreach(log).sum { |l| l[/\A[.*FE]+/].to_s.length } rescue 0

    puts "spec:parallel: process #{index} CRASHED: it #{how} without its JSON report after #{progress} examples (log #{display_path(log)})"
    puts "  #{bug.strip[0, 200]}" if bug
    puts "  Its #{files.length} files:"
    files.each { |f| puts "    #{f}" }
  end

  def display_path(path)
    path.delete_prefix("#{ROOT}/")
  end
end
