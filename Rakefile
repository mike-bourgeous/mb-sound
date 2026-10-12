require "bundler/gem_tasks"
require 'rake/extensiontask'
require 'shellwords'

task :default => :spec

Rake::ExtensionTask.new 'mb-fast_sound' do |ext|
  ext.name = 'fast_sound'
  ext.ext_dir = 'ext/mb/fast_sound'
  ext.lib_dir = 'lib/mb'
end

Rake::ExtensionTask.new 'mb-sound-fast_resample' do |ext|
  ext.name = 'fast_resample'
  ext.ext_dir = 'ext/mb/sound/fast_resample'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_wavetable' do |ext|
  ext.name = 'fast_wavetable'
  ext.ext_dir = 'ext/mb/sound/fast_wavetable'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_delay' do |ext|
  ext.name = 'fast_delay'
  ext.ext_dir = 'ext/mb/sound/fast_delay'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_synth' do |ext|
  ext.name = 'fast_synth'
  ext.ext_dir = 'ext/mb/sound/fast_synth'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_clip' do |ext|
  ext.name = 'fast_clip'
  ext.ext_dir = 'ext/mb/sound/fast_clip'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_arithmetic' do |ext|
  ext.name = 'fast_arithmetic'
  ext.ext_dir = 'ext/mb/sound/fast_arithmetic'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_envelope' do |ext|
  ext.name = 'fast_envelope'
  ext.ext_dir = 'ext/mb/sound/fast_envelope'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_resonator' do |ext|
  ext.name = 'fast_resonator'
  ext.ext_dir = 'ext/mb/sound/fast_resonator'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_filter' do |ext|
  ext.name = 'fast_filter'
  ext.ext_dir = 'ext/mb/sound/fast_filter'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_loudness' do |ext|
  ext.name = 'fast_loudness'
  ext.ext_dir = 'ext/mb/sound/fast_loudness'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_dynamics' do |ext|
  ext.name = 'fast_dynamics'
  ext.ext_dir = 'ext/mb/sound/fast_dynamics'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_recipe' do |ext|
  ext.name = 'fast_recipe'
  ext.ext_dir = 'ext/mb/sound/fast_recipe'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_lofi' do |ext|
  ext.name = 'fast_lofi'
  ext.ext_dir = 'ext/mb/sound/fast_lofi'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_unison' do |ext|
  ext.name = 'fast_unison'
  ext.ext_dir = 'ext/mb/sound/fast_unison'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_control' do |ext|
  ext.name = 'fast_control'
  ext.ext_dir = 'ext/mb/sound/fast_control'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_audio' do |ext|
  ext.name = 'fast_audio'
  ext.ext_dir = 'ext/mb/sound/fast_audio'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_midi' do |ext|
  ext.name = 'fast_midi'
  ext.ext_dir = 'ext/mb/sound/fast_midi'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_plan' do |ext|
  ext.name = 'fast_plan'
  ext.ext_dir = 'ext/mb/sound/fast_plan'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_loop' do |ext|
  ext.name = 'fast_loop'
  ext.ext_dir = 'ext/mb/sound/fast_loop'
  ext.lib_dir = 'lib/mb/sound'
end

Rake::ExtensionTask.new 'mb-sound-fast_reverb' do |ext|
  ext.name = 'fast_reverb'
  ext.ext_dir = 'ext/mb/sound/fast_reverb'
  ext.lib_dir = 'lib/mb/sound'
end


# Valgrind memcheck of the C extensions (`bundle exec rake memcheck`), using
# ruby_memcheck, which runs rspec under Valgrind and filters out Ruby's own
# leaks.  Invalid reads/writes are reported wherever they happen; leaks only
# when an extension's code is on the allocation stack.  Needs valgrind >=
# 3.20 (apt install valgrind).  Takes several minutes.
#
#   MEMCHECK_SPECS="spec/a_spec.rb spec/b_spec.rb"  run other specs
#   MEMCHECK_GEN_SUPPRESSIONS=1                     print suppressions for errors
#   MEMCHECK_GC_STRESS=1                           GC.stress during each extension call
#                                                   (spec/valgrind/gc_stress_calls.rb)
#   MEMCHECK_UNDEF=1                                also report uses of uninitialized
#                                                   values with an extension on the stack
#   rake memcheck:debug                             rebuild extensions at -O0 first
#
# Selective runs (spec/valgrind/memcheck_selection.rb has the rules):
#
#   rake memcheck:changed[BASE,TO]  only the specs for extensions changed since
#                                   the merge-base of HEAD and BASE (default
#                                   master-ai), up to TO (default: the working
#                                   tree, uncommitted and untracked included)
#     MEMCHECK_DRY=1                print the selection, don't run Valgrind
#     FULL=auto                     run the full list when a full run is due
#     FULL=1                        run the full list
#   rake memcheck:status            last full run and whether one is due
#   rake memcheck:map               rerecord spec/valgrind/memcheck_map.json
#                                   (natively, ~5 min; a full run does it too
#                                   unless MEMCHECK_MAP=0)
#   rake depend:check               compare ext depend files with the includes
#
# A full run (no MEMCHECK_SPECS) writes the stamp in the main checkout's
# tmp/memcheck_full.stamp and refreshes the map.
#
# Suppressions for known false positives go in spec/valgrind/ruby.supp (or
# ruby-4.0.supp etc. for one Ruby version).
# The spec list and the selection for `memcheck:changed` are in
# spec/valgrind/memcheck_selection.rb.
require_relative 'spec/valgrind/memcheck_selection'
MEMCHECK_SPECS = MemcheckSelection::SPECS

begin
  require 'ruby_memcheck'
  require 'ruby_memcheck/rspec/rake_task'

  # Valgrind stops writing a process's XML when it execs a program that
  # --trace-children-skip excludes (e.g. `sh -c ffmpeg ...`), and
  # ruby_memcheck aborts on the unterminated file.  Close such files before
  # parsing; a truncated file still reports any errors written before the
  # exec.
  module MemcheckTruncatedXml
    private def parse_valgrind_output
      valgrind_xml_files.each do |f|
        xml = File.read(f)
        next if xml.include?('</valgrindoutput>')
        # Cut after the last complete top-level element, then close the root
        ends = xml.to_enum(:scan, %r{<valgrindoutput>|</(?:preamble|args|status|error|errorcounts|suppcounts)>}).map { $~.end(0) }
        File.write(f, "#{xml[0...ends.last.to_i]}\n</valgrindoutput>\n")
      end
      super
    end
  end
  RubyMemcheck::TestTaskReporter.prepend(MemcheckTruncatedXml)

  # With MEMCHECK_UNDEF=1, Ruby's conservative GC stack scanning gives
  # thousands of uninitialized-value errors (gc_mark_set, is_pointer_to_heap,
  # ...), many while an extension is on the stack.  Keep only those where
  # the value is used in this project's extensions, or in a library they
  # called (libm, libsamplerate, ...), before control returns to libruby.
  module MemcheckUndefFilter
    EXT_DIR = File.join(__dir__, 'lib', '')

    def skip?
      return super unless kind.start_with?('Uninit')

      stack.frames.take_while { |f| !f.in_ruby? }.none? { |f| f.obj.to_s.start_with?(EXT_DIR) }
    end
  end
  RubyMemcheck::ValgrindError.prepend(MemcheckUndefFilter)

  # Built when the task runs: RubyMemcheck::Configuration creates a temp
  # directory, which would otherwise be left behind by every rake command.
  memcheck_config = lambda do
    RubyMemcheck::Configuration.new(
      valgrind_options: [
        *RubyMemcheck::Configuration::DEFAULT_VALGRIND_OPTIONS,
        *(ENV['MEMCHECK_UNDEF'] == '1' ? ['--undef-value-errors=yes', '--track-origins=yes'] : []),
        # --trace-children=yes (a default) keeps the GC.stress `ruby -e` load
        # specs under Valgrind; ffmpeg and other tools run natively.  A
        # process that execs a skipped program leaves truncated XML, which
        # MemcheckTruncatedXml above cleans up.
        # jackd: the MIDI specs' dummy JACK server (spec/support/jack_dummy.rb),
        # started through setpriv.
        '--trace-children-skip=*ffmpeg*,*ffprobe*,*gnuplot*,*/dot,*/git,*jackd*,*setpriv*',
        # Forked children that don't exec (fork_script) would repeat the
        # parent's leak report, so only exec'd programs report.
        '--child-silent-after-fork=yes',
      ],
      valgrind_suppressions_dir: 'spec/valgrind',
      valgrind_generate_suppressions: ENV['MEMCHECK_GEN_SUPPRESSIONS'] == '1',
    )
  end

  # Runs +specs+ under Valgrind; a full run (the whole list) then writes the
  # full-run stamp and refreshes the spec map (MEMCHECK_MAP=0 skips that).
  run_memcheck = lambda do |specs, full:|
    config = memcheck_config.call
    task_name = :"memcheck_rspec_#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    # Specs shrink their inputs and skip memcheck_skip examples under
    # Valgrind (SPEC_MEMCHECK in spec/spec_helper.rb); per-example times go to
    # tmp/memcheck_times.json (for finding what to trim next).
    ENV['MB_SOUND_MEMCHECK'] = '1'
    RubyMemcheck::RSpec::RakeTask.new(config, task_name) do |t|
      t.pattern = specs
      t.rspec_opts = ['--format', 'progress', '--format', 'json', '--out', 'tmp/memcheck_times.json']
      t.rspec_opts += ['--require', './spec/valgrind/gc_stress_calls.rb'] if ENV['MEMCHECK_GC_STRESS'] == '1'
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      Rake::Task[task_name].invoke
    ensure
      ENV.delete('MB_SOUND_MEMCHECK')
    end
    puts format('memcheck: %d spec files clean in %.1f min', Array(specs).length, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 60)
    if full
      stamp = MemcheckSelection.write_stamp
      puts "memcheck: full run recorded in #{MemcheckSelection.stamp_path} (#{stamp['commit'][0, 10]}#{stamp['dirty'] ? ', uncommitted changes' : ''})"
      Rake::Task['memcheck:map'].invoke unless ENV['MEMCHECK_MAP'] == '0'
    end
  ensure
    FileUtils.rm_rf(config.temp_dir) if config
  end

  desc 'Run the C extension specs under Valgrind memcheck (MEMCHECK_SPECS=... for others)'
  task memcheck: :compile do
    specs = ENV['MEMCHECK_SPECS'].to_s.split
    run_memcheck.call(specs.empty? ? MEMCHECK_SPECS : specs, full: specs.empty?)
  end

  namespace :memcheck do
    desc 'Rebuild the extensions at -O0 (exact Valgrind line numbers), then run memcheck; `rake clobber compile` restores -O3'
    task :debug do
      # Later flags win, so these override extconf.rb's -O3.  -O0 disables
      # _FORTIFY_SOURCE, whose warning would fail -Werror.
      ENV['EXTRACFLAGS'] = "-O0 -U_FORTIFY_SOURCE #{ENV['EXTRACFLAGS']}"
      Rake::Task['clobber'].invoke # extconf flags are only read when tmp/ is empty
      Rake::Task['memcheck'].invoke
    end

    desc 'Memcheck only the specs for extensions changed since the merge-base with BASE (default master-ai); MEMCHECK_DRY=1 prints the selection, FULL=auto|1'
    task :changed, [:base, :to] do |_, args|
      sel = MemcheckSelection.select(base: args[:base], to: args[:to])
      MemcheckSelection.describe(sel)
      due, status = MemcheckSelection.full_status
      puts status
      full = sel.full? || ENV['FULL'] == '1' || (ENV['FULL'] == 'auto' && due)
      puts "FULL=#{ENV['FULL']}: running the full list (#{MEMCHECK_SPECS.length} globs)" if full && !sel.full?
      next if ENV['MEMCHECK_DRY'] == '1'
      next puts('memcheck:changed: nothing to run') if sel.empty? && !full

      Rake::Task[:compile].invoke
      run_memcheck.call(full ? MEMCHECK_SPECS : sel.specs, full: full)
    end
  end
rescue LoadError => e
  desc 'Run the C extension specs under Valgrind memcheck (needs the ruby_memcheck gem)'
  task(:memcheck) { abort "rake memcheck needs the ruby_memcheck gem (bundle install): #{e.message}" }
end

namespace :memcheck do
  desc 'Show the last full memcheck run and whether one is due'
  task :status do
    puts MemcheckSelection.full_status[1]
  end

  # In memcheck mode (MB_SOUND_MEMCHECK=1, as under Valgrind), so the map
  # lists the calls the Valgrind runs make (memcheck_skip examples left out)
  desc 'Record which extensions each memcheck spec calls (spec/valgrind/memcheck_map.json; native rspec, a few minutes)'
  task :map do
    sh({ 'MEMCHECK_MAP' => '1', 'MB_SOUND_MEMCHECK' => '1' }, 'bundle', 'exec', 'rspec', *MemcheckSelection.spec_files)
  end
end

namespace :spec do
  desc 'Run the specs in PARALLEL (default 4) rspec processes, then list the slowest files and examples (SPECS="spec/lib ..." for a subset)'
  task :parallel do
    require_relative 'spec/parallel_specs'
    ok = ParallelSpecs.run(count: Integer(ENV['PARALLEL'] || 4), patterns: ENV['SPECS'].to_s.split)
    abort 'spec:parallel: failures' unless ok
  end
end

# The plan layer's full block-size sweep (user decision 2026-10-10: not run
# before every merge, only for branches that change the plan layer itself).
# The default suite runs plan comparisons at block sizes 1, 7, 128, 800, and
# one random size seeded by RSpec's seed; MB_SOUND_PLAN_FULL=1 runs the
# 21-size sweep (see spec/support/plan_helpers.rb).
PLAN_FULL_SPECS = %w[
  spec/lib/mb/sound/plan
  spec/lib/mb/sound/graph_node/feedback_loop_spec.rb
  spec/ext/mb/sound/fast_plan_spec.rb
  spec/ext/mb/sound/fast_loop_spec.rb
].freeze

# Paths whose changes make the full sweep due (plan:changed).
PLAN_FULL_PATHS = %w[
  lib/mb/sound/plan.rb
  lib/mb/sound/plan
  ext/mb/sound/fast_plan
  ext/mb/sound/fast_loop
  spec/support/plan_helpers.rb
].freeze

namespace :plan do
  desc 'Run the plan specs with the full 21-size block sweep (MB_SOUND_PLAN_FULL=1; ~1 min)'
  task :full do
    sh({ 'MB_SOUND_PLAN_FULL' => '1' }, 'bundle', 'exec', 'rspec', *PLAN_FULL_SPECS)
  end

  desc 'Run plan:full if the branch changed the plan layer since the merge-base with BASE (default master-ai) by PLAN_FULL_LINES (default 50) lines or more; PLAN_DRY=1 only reports'
  task :changed, [:base] do |_, args|
    base = args[:base] || ENV['BASE'] || 'master-ai'
    merge_base = `git merge-base HEAD #{base.shellescape}`.strip
    abort "plan:changed: no merge-base with #{base}" if merge_base.empty?

    # Committed and uncommitted changes (git diff against the merge-base
    # includes the working tree), plus untracked files
    stats = `git diff --numstat #{merge_base} -- #{PLAN_FULL_PATHS.shelljoin}`.lines.map(&:split)
    untracked = `git ls-files --others --exclude-standard -- #{PLAN_FULL_PATHS.shelljoin}`.lines.map(&:chomp)
    lines = stats.sum { |add, del, _| add.to_i + del.to_i } + untracked.sum { |f| File.foreach(f).count rescue 0 }
    files = stats.map(&:last) + untracked
    threshold = Integer(ENV['PLAN_FULL_LINES'] || 50)
    due = lines >= threshold

    puts "plan:changed: #{files.length} plan-layer files changed since #{merge_base[0, 10]} (#{base}), #{lines} lines; " \
      "the full sweep is #{due ? 'DUE' : 'not needed'} (threshold #{threshold} lines)"
    files.first(20).each { |f| puts "  #{f}" }
    next if ENV['PLAN_DRY'] == '1' || !due

    Rake::Task['plan:full'].invoke
  end
end

namespace :depend do
  desc "Check every extension's depend file against the headers its sources include"
  task :check do
    problems = MemcheckSelection.depend_problems
    abort("depend:check:\n  #{problems.join("\n  ")}") unless problems.empty?
    puts "depend:check: #{MemcheckSelection.extensions.length} extensions OK"
  end
end
