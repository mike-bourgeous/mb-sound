# The merge train (test-infra-1, 2026-10-30; the maintainer's choice of
# option 2 on the review queue page): each merge into master-ai runs a gate
# of 1-3 minutes instead of the full suite and smoke, and the batch
# of merges ends with one full run (MergeGate.batch).
#
# The gate (`rake merge:gate`, after compiling):
# - the spec files of units changed on either side of the merge: every file
#   changed from the merge-base of its two parents to the merge, mapped by
#   QuickSelection.direct (mirror paths, names, top-level describes, and
#   QuickSelection::PATH_RULES for the Rakefile, spec helpers, presets, ...),
#   and changed spec files;
# - QuickSelection::ALWAYS (whole-library guards and property sweeps, at
#   the default tier) and GUARDS (cheap whole-library guards no unit points
#   at);
# - the gems' specs (mb-term, a few seconds) and, when ext/ changed,
#   depend:check;
# with time budgets reported, not failing (MB_SOUND_SPEC_BUDGET=report:
# merges run on a loaded machine).  It prints what it chose and why.
#
# Replayed on the 2026-10-29 batch (7 merges, Mac container, PARALLEL=8):
# 52-175 spec files a merge, 0.6-2.7 min each (the longest file sets the
# floor: help_spec alone ran 108 s under load), and it finds what that
# batch's seven full suites and hand-picked runs found: literal_binding_spec
# at ced1a1d8, the Rakefile text guard at 2538134d (PATH_RULES), the
# `rhythm` clash (name_clash_guard_spec, in ALWAYS) in that merge rebuilt
# without its fix, and the stale libraries at 00dd9a0f (rebuilt by the
# compile first).  merge_gate_spec.rb keeps the selection replays.
#
# The batch end (`rake merge:batch`, once per batch, in the background):
# the full suite with the slow tier (spec:full), smoke, golden:check, and a
# fuzz soak (session and relation fuzz in parallel processes on fresh
# seeds).  A failure there is found at the end of the batch: run the
# failing spec at each merge of the batch to find the merge it came from.
require 'json'
require 'fileutils'
require 'rbconfig'
require_relative 'quick_selection'

module MergeGate
  ROOT = QuickSelection::ROOT

  # Cheap whole-library guards (each a few seconds at most) that the gate
  # runs whatever changed, besides QuickSelection::ALWAYS: they check
  # declarations, names, or boundaries that a change anywhere can break.
  GUARDS = %w[
    spec/lib/mb/sound/graph_node/recipe_spec.rb
    spec/lib/mb/sound/param_guard_spec.rb
    spec/bin/param_declarations_spec.rb
    spec/bin/shebang_spec.rb
    spec/lib/mb/sound/library_spec.rb
    spec/lib/mb/sound/api_guesses_spec.rb
    spec/lib/mb/sound/exit_close_spec.rb
    spec/lib/mb/sound/session/ivar_layout_spec.rb
    spec/lib/mb/sound/graph_node/ivar_preset_spec.rb
    spec/lib/mb/sound/graph_node/frozen_view_spec.rb
    spec/lib/mb/sound/output_api_guard_spec.rb
    spec/lib/mb/sound/render_path_guard_spec.rb
    spec/lib/mb/sound/audio_io_boundary_spec.rb
    spec/lib/mb/sound/plot/plot_boundary_spec.rb
    spec/stale_extensions_spec.rb
    spec/merge_gate_spec.rb
  ].freeze

  # The gems in gems/ whose specs run in their own processes.
  GEM_DIRS = %w[gems/mb-term].freeze

  Selection = Struct.new(:merge, :ours, :theirs, :base, :worktree, :changed, :specs, :reasons, keyword_init: true)

  module_function

  def git(*args, chdir: ROOT)
    out = IO.popen(['git', *args], chdir: chdir, err: File::NULL, &:read)
    $?.success? ? out : nil
  end

  def rev(ref) = git('rev-parse', '--verify', '--quiet', "#{ref}^{commit}")&.strip

  # The two sides of the merge to check:
  # - no arguments: an unfinished merge (MERGE_HEAD: HEAD and MERGE_HEAD,
  #   the working tree as the result), else HEAD as a merge commit (plus
  #   any uncommitted changes on top of it);
  # - +merge+: that merge commit, committed changes only (replays);
  # - +merge+ and +theirs+: the two sides, the working tree as the result.
  # Returns [merge label, ours, theirs, include the working tree?].
  def sides(merge = nil, theirs = nil)
    merge = nil if merge.to_s.empty?
    theirs = nil if theirs.to_s.empty?
    if theirs
      return [nil, rev(merge) || raise(ArgumentError, "merge:gate: no commit #{merge}"), rev(theirs) || raise(ArgumentError, "merge:gate: no commit #{theirs}"), true]
    end

    if merge.nil?
      head = rev('MERGE_HEAD')
      return [nil, rev('HEAD'), head, true] if head
    end

    commit = rev(merge || 'HEAD') or raise ArgumentError, "merge:gate: no commit #{merge}"
    parents = git('rev-list', '--parents', '-n', '1', commit).split.drop(1)
    unless parents.length == 2
      raise ArgumentError, "merge:gate: #{merge || 'HEAD'} (#{commit[0, 10]}) is not a merge of two parents and no merge is in progress; " \
                           'give the merge commit (merge:gate[sha]) or the two sides (merge:gate[ours,theirs])'
    end

    [commit, *parents, merge.nil?]
  end

  # Files changed on either side: from the merge-base of the two sides to
  # the merge commit, or to the working tree (untracked files included).
  def changed_files(base, merge, worktree)
    files = []
    files += git('diff', '--name-only', '--no-renames', base, merge).to_s.lines if merge
    if worktree
      files += git('diff', '--name-only', '--no-renames', base).to_s.lines
      files += git('ls-files', '--others', '--exclude-standard').to_s.lines
    end
    files.map(&:chomp).reject(&:empty?).uniq.sort
  end

  def select(merge: nil, theirs: nil, changed: nil)
    label, ours, other, worktree = changed ? [nil, nil, nil, false] : sides(merge, theirs)
    base = git('merge-base', ours, other)&.strip unless changed
    raise ArgumentError, "merge:gate: no merge-base of #{ours} and #{other}" unless changed || (base && !base.empty?)

    changed ||= changed_files(base, label, worktree)
    specs = QuickSelection.spec_files
    reasons = Hash.new { |h, k| h[k] = [] }
    QuickSelection::ALWAYS.each { |s| reasons[s] << :always }
    GUARDS.each { |s| reasons[s] << :guard }
    changed.each do |f|
      if f.start_with?('spec/') && f.end_with?('_spec.rb')
        reasons[f] << :changed
      else
        QuickSelection.direct(f, specs).each { |s| reasons[s] << :"unit #{f}" }
      end
    end
    reasons.select! { |s, _| specs.include?(s) }
    Selection.new(merge: label, ours: ours, theirs: other, base: base, worktree: worktree, changed: changed,
                  specs: reasons.keys.sort, reasons: reasons)
  end

  def short(sha) = sha ? sha[0, 10] : 'the working tree'

  # Prints the selection: what was merged, counts by reason, the expected
  # time from the last measured file times, and each changed-unit spec
  # with the files that chose it.
  def describe(sel, times: {}, io: $stdout)
    if sel.ours
      io.puts "merge:gate: #{sel.merge ? "merge #{short(sel.merge)}" : 'the working tree'} of #{short(sel.ours)} and #{short(sel.theirs)} " \
              "(merge-base #{short(sel.base)}#{sel.worktree && sel.merge ? ', plus uncommitted changes' : ''})"
    end
    total = times.values.sum
    t = sel.specs.sum { |s| times[s] || 0 }
    counts = Hash.new(0)
    sel.reasons.each_value { |r| counts[r.first.to_s.start_with?('unit') ? :unit : r.first] += 1 }
    io.puts "merge:gate: #{sel.changed.length} changed files -> #{sel.specs.length} of #{QuickSelection.spec_files.length} spec files " \
            "(#{counts[:always]} always, #{counts[:guard]} guards, #{counts[:unit]} changed units, #{counts[:changed]} changed specs)" \
            "#{total > 0 ? format('; %.0f s of %.0f s of last measured example time (%.0f%%)', t, total, 100 * t / total) : ''}"
    sel.reasons.select { |_, r| r.any? { |x| x.to_s.start_with?('unit') || x == :changed } }.sort.each do |s, r|
      why = r.map(&:to_s).map { |x| x.delete_prefix('unit ') }.uniq
      io.puts "  #{s}  <- #{why.first(3).join(', ')}#{why.length > 3 ? " and #{why.length - 3} more" : ''}"
    end
    unmatched = sel.changed.reject { |f| f.start_with?('spec/') || f.match?(%r{\A(design|research|\.claude|docs?)/|\.md\z}) || QuickSelection.direct(f).any? }
    io.puts "merge:gate: changed files no spec points at (#{unmatched.length}): #{unmatched.first(12).join(', ')}#{unmatched.length > 12 ? ', ...' : ''}" unless unmatched.empty?
  end

  # Runs the gems' specs, each in its own directory and process.  Returns
  # true when they pass.
  def run_gem_specs
    GEM_DIRS.select { |d| Dir.exist?(File.join(ROOT, d)) }.all? do |dir|
      puts "merge:gate: #{dir} specs"
      system('bundle', 'exec', 'rspec', chdir: File.join(ROOT, dir))
    end
  end

  # Selects and runs the gate (compiling is the rake task's prerequisite;
  # +compile+ runs it here for callers outside rake).  Returns true when
  # everything passed.
  def run(merge: nil, theirs: nil, compile: false, dry: ENV['MERGE_DRY'] == '1')
    require_relative 'parallel_specs'
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sel = select(merge: merge, theirs: theirs)
    describe(sel, times: ParallelSpecs.known_times)
    return true if dry

    if compile
      ok = system('bundle', 'exec', 'rake', '-f', 'Rakefile', 'compile', chdir: ROOT, out: File::NULL)
      abort 'merge:gate: compile failed (bundle exec rake -f Rakefile compile)' unless ok
    end
    ENV['MB_SOUND_SPEC_BUDGET'] = 'report' # (a merge runs on a loaded machine; budgets are checked on branches)
    ok = ParallelSpecs.run_default(patterns: sel.specs)
    gems = run_gem_specs
    depend = true
    if sel.changed.any? { |f| f.start_with?('ext/') }
      require_relative 'valgrind/memcheck_selection'
      problems = MemcheckSelection.depend_problems
      puts(problems.empty? ? 'merge:gate: depend:check OK' : "merge:gate: depend:check:\n  #{problems.join("\n  ")}")
      depend = problems.empty?
    end
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    passed = ok && gems && depend
    puts format('merge:gate: %s in %.1f min (%d spec files)%s', passed ? 'PASSED' : 'FAILED', wall / 60, sel.specs.length,
                passed ? '' : "; failing: #{[('specs' unless ok), ('gem specs' unless gems), ('depend:check' unless depend)].compact.join(', ')}")
    advise(sel)
    passed
  end

  # What the batch end should also run for this merge (printed, not run).
  def advise(sel)
    notes = []
    notes << 'ext/ changed: memcheck:changed before the batch ends' if sel.changed.any? { |f| f.match?(%r{\A(ext|gems/[^/]+/ext)/}) }
    notes << 'plan layer changed: rake plan:changed' if sel.changed.any? { |f| f.match?(%r{\A(lib/mb/sound/plan|ext/mb/sound/fast_(plan|loop))}) }
    notes << 'bin/ changed: smoke at the batch end covers it' if sel.changed.any? { |f| f.start_with?('bin/') }
    notes.each { |n| puts "merge:gate: #{n}" }
  end

  # The batch end's steps, in order: [name, env, command].
  def batch_steps(soak_session: Integer(ENV['SOAK_SESSION'] || 24), soak_relation: Integer(ENV['SOAK_RELATION'] || 200), base: nil)
    base ||= Integer(ENV['SOAK_BASE'] || (Time.now.to_i / 86_400 % 1000) * 1000 + 10_000)
    rake = %w[bundle exec rake -f Rakefile]
    [
      ['suite', { 'SLOW' => '1', 'MB_SOUND_SPEC_BUDGET' => 'report' }, [*rake, 'spec:parallel']],
      ['smoke', {}, %w[bundle exec rspec --tag smoke]],
      ['golden', {}, [*rake, 'golden:check']],
      ['soak', {}, [:soak, soak_session, soak_relation, base]],
    ]
  end

  # The fuzz soak: session fuzz in 4 processes and relation fuzz in 2, on
  # seeds from +base+ (fresh each day unless SOAK_BASE is given; printed
  # for repros), writing logs to +dir+.  Returns true when all pass.
  def soak(session, relation, base, dir)
    jobs = []
    per = (session / 4.0).ceil
    4.times { |i| jobs << ['session', base + i * per, per, 'spec/lib/mb/sound/session_fuzz_spec.rb'] } if session > 0
    rper = (relation / 2.0).ceil
    2.times { |i| jobs << ['relation', base + 500 + i * rper, rper, 'spec/lib/mb/sound/relation_fuzz_spec.rb'] } if relation > 0
    pids = jobs.each_with_index.map do |(kind, b, n, spec), i|
      log = File.join(dir, "soak_#{kind}_#{i}.txt")
      puts "merge:batch: #{kind} fuzz FUZZ_BASE=#{b} FUZZ=#{n} -> #{log}"
      [Process.spawn({ 'FUZZ' => n.to_s, 'FUZZ_BASE' => b.to_s }, 'bundle', 'exec', 'rspec', spec, chdir: ROOT, out: log, err: %i[child out]), log]
    end
    pids.map { |pid, log|
      Process.wait(pid)
      ok = $?.success?
      puts "merge:batch: #{File.basename(log)} #{ok ? 'passed' : 'FAILED'} #{File.foreach(log).grep(/fuzz: \d+ seeds/).first&.strip}"
      ok
    }.all?
  end

  # Runs the batch end in +dir+ (outputs per step; BATCH_STEPS=a,b picks
  # steps).  Every step runs even after a failure.  Returns true when all
  # passed.
  def batch(dir: ENV['OUT'] || File.join(ROOT, 'tmp', 'merge_batch', Time.now.strftime('%Y%m%d-%H%M%S')), steps: ENV['BATCH_STEPS'].to_s.split(','))
    FileUtils.mkdir_p(dir)
    puts "merge:batch: output in #{dir}"
    results = batch_steps.filter_map do |name, env, cmd|
      next if !steps.empty? && !steps.include?(name)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = File.join(dir, "#{name}.txt")
      ok =
        if cmd.first == :soak
          soak(*cmd.drop(1), dir)
        else
          puts "merge:batch: #{name}: #{env.map { |k, v| "#{k}=#{v} " }.join}#{cmd.join(' ')} -> #{out}"
          system(env, *cmd, chdir: ROOT, out: out, err: %i[child out])
        end
      mins = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 60
      summary = File.exist?(out) ? File.foreach(out).grep(/examples, \d+ failure|not passing|golden:check|spec:parallel: \d+ examples/).last&.strip : nil
      puts format('merge:batch: %-6s %s in %.1f min %s', name, ok ? 'passed' : 'FAILED', mins, summary)
      File.foreach(out).grep(/^rspec /).first(10).each { |l| puts "  #{l}" } if !ok && File.exist?(out)
      [name, ok]
    end
    bad = results.reject(&:last).map(&:first)
    puts(bad.empty? ? 'merge:batch: all passed' : "merge:batch: FAILED: #{bad.join(', ')}; find each failing spec's merge by running it at each merge of the batch")
    bad.empty?
  end
end
