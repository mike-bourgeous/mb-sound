# Per-spec-file line and branch coverage, for rake spec:quick:map (the
# covering set in spec/quick_map.json; spec/quick_selection.rb) and the
# test-selection study (research-test-selection, 2026-10-24).  Loaded first
# by spec/spec_helper.rb when MB_SOUND_COVERAGE_PER_FILE=DIR names an output
# directory:
#
#   MB_SOUND_COVERAGE_PER_FILE=/tmp/cov bundle exec rspec
#
# Ruby's Coverage (lines + branches) starts before the library loads.  At
# the start of every top-level example group (groups run in random order,
# so a file's groups aren't contiguous) and after the suite, the counts so
# far are taken with Coverage.result(clear: true) and added to the spec file
# that was running, together with the coverage of any Ruby subprocesses or
# forked scripts it ran (written by spec/subprocess_coverage_helper.rb and
# fork_script into a directory of our own).  What ran before the first
# group (loading the library and the spec files) is kept as "baseline":
# every run gets it for free.
#
# Each process writes DIR/<pid>.json:
#   { "baseline": { path => { "l" => [lines], "b" => [branch keys] } },
#     "files": { spec_file => { path => {...} } },
#     "all": { path => { "l" => n_relevant_lines, "b" => [all branch keys] } } }
# Paths are relative to the checkout and limited to lib/ and bin/.  Branch
# keys are "cond_type:line:col/target_type:line:col:end_line:end_col" (no
# Coverage ids, so they match across processes).
require 'coverage'
require 'json'
require 'fileutils'
require 'set'

Coverage.start(lines: true, branches: true) unless Coverage.running?

module PerFileCoverage
  ROOT = File.expand_path('../..', __dir__) + '/'
  OUT = ENV.fetch('MB_SOUND_COVERAGE_PER_FILE')
  SUB_DIR = File.join(OUT, "sub-#{Process.pid}")
  KEY_RE = /\A\[:(\w+), -?\d+, (\d+), (\d+), (\d+), (\d+)\]\z/

  @baseline = nil
  @files = Hash.new { |h, k| h[k] = {} }
  @all = {}
  @current = nil
  @owner = Process.pid

  class << self
    # Sends Ruby subprocesses' and forked scripts' coverage to SUB_DIR (the
    # same helper and format SIMPLECOV=1 uses; see support/subprocess_coverage.rb).
    def setup_subprocesses!
      FileUtils.mkdir_p(SUB_DIR)
      ENV['MB_SOUND_SUBPROCESS_COVERAGE'] = SUB_DIR
      ENV['RUBYOPT'] = "#{WarningGuard.rubyopt} -r#{File.join(ROOT, 'spec/subprocess_coverage_helper.rb')}"
      Object.const_set(:SubprocessCoverage, Module.new) unless defined?(::SubprocessCoverage)
      ::SubprocessCoverage.const_set(:DIR, SUB_DIR) unless ::SubprocessCoverage.const_defined?(:DIR)
    end

    # Starts attributing coverage to +spec_file+, giving what ran since the
    # last switch to the file that was running.
    def switch(spec_file)
      flush
      @current = spec_file.delete_prefix('./')
    end

    def flush
      return unless Process.pid == @owner

      result = Coverage.result(stop: false, clear: true)
      target = @current ? @files[@current] : (@baseline ||= {})
      add_native(target, result)
      Dir[File.join(SUB_DIR, '*.json')].each do |f|
        add_json(target, JSON.parse(File.read(f)))
        File.delete(f)
      rescue JSON::ParserError
        nil
      end
    end

    def finish
      return unless Process.pid == @owner

      flush
      FileUtils.mkdir_p(OUT)
      out = {
        'baseline' => pack(@baseline || {}),
        'files' => @files.transform_values { |h| pack(h) },
        'all' => @all.transform_values { |a| { 'l' => a[:l], 'b' => a[:b].to_a } },
      }
      File.write(File.join(OUT, "#{Process.pid}.json"), JSON.dump(out))
    end

    private

    def relative(path)
      return nil unless path.start_with?(ROOT)

      rel = path.delete_prefix(ROOT)
      rel.start_with?('lib/', 'bin/') ? rel : nil
    end

    def entry(target, rel)
      target[rel] ||= { l: Set.new, b: Set.new }
    end

    def record_all(rel, n_lines, keys)
      a = (@all[rel] ||= { l: 0, b: Set.new })
      a[:l] = n_lines if n_lines > a[:l]
      a[:b].merge(keys)
    end

    # Coverage.result format: branch conditions and targets are Arrays.
    def add_native(target, result)
      result.each do |path, cov|
        rel = relative(path) or next
        e = entry(target, rel)
        lines = cov[:lines] || []
        lines.each_with_index { |n, i| e[:l] << (i + 1) if n && n > 0 }
        keys = []
        (cov[:branches] || {}).each do |cond, targets|
          ck = "#{cond[0]}:#{cond[2]}:#{cond[3]}"
          targets.each do |t, n|
            k = "#{ck}/#{t[0]}:#{t[2]}:#{t[3]}:#{t[4]}:#{t[5]}"
            keys << k
            e[:b] << k if n > 0
          end
        end
        record_all(rel, lines.count { |n| n }, keys)
      end
    end

    # The subprocess files: JSON of the same Hash, so keys are inspected Arrays.
    def add_json(target, result)
      result.each do |path, cov|
        rel = relative(path) or next
        e = entry(target, rel)
        lines = cov['lines'] || []
        lines.each_with_index { |n, i| e[:l] << (i + 1) if n && n > 0 }
        keys = []
        (cov['branches'] || {}).each do |cond, targets|
          c = KEY_RE.match(cond) or next
          ck = "#{c[1]}:#{c[2]}:#{c[3]}"
          targets.each do |t, n|
            m = KEY_RE.match(t) or next
            k = "#{ck}/#{m[1]}:#{m[2]}:#{m[3]}:#{m[4]}:#{m[5]}"
            keys << k
            e[:b] << k if n > 0
          end
        end
        record_all(rel, lines.count { |n| n }, keys)
      end
    end

    def pack(h)
      h.transform_values { |e| { 'l' => e[:l].to_a.sort, 'b' => e[:b].to_a } }.reject { |_, v| v['l'].empty? && v['b'].empty? }
    end
  end
end

RSpec.configure do |config|
  config.before(:context) do
    PerFileCoverage.switch(self.class.metadata[:file_path]) if self.class.metadata[:parent_example_group].nil?
  end

  config.after(:suite) do
    PerFileCoverage.finish
  end
end
