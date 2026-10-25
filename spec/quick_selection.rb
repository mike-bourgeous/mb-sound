# Selection for `rake spec:quick` (test-tiers-1, 2026-10-25): the
# maintainer's everyday rule, "the 95% coverage set plus the spec files of
# directly changed units" (merges still run the full suite, slow tier
# included).  The spec files run are:
#
# - the covering set in spec/quick_map.json: the cheapest spec files (by
#   their last measured times) that reach 95% of the lib/ branches the whole
#   suite reaches, from per-file coverage (`rake spec:quick:map`);
# - ALWAYS: whole-library guards and the property sweeps (buffer-size
#   invariance, take replays, the graph sweep, the relation fuzzer), which no
#   unit name points at;
# - the spec files of units changed since the merge-base with master-ai
#   (#direct): the mirror path (lib/a/b.rb -> spec/lib/a/b_spec.rb, bin/x.rb
#   -> spec/bin/x_spec.rb, ext/mb/sound/fast_x/ -> spec/ext/mb/sound/fast_x_spec.rb),
#   spec files named after the file (tone.rb -> tone_gain_spec.rb), and spec
#   files whose top-level describe names its class or module;
# - changed and untracked spec files, and spec files newer than the map.
#
# Replayed on 143 fix commits (research-test-selection, rule_replay.rb), the
# rule selected every spec file a fix changed for 80% of them (89% of the
# commit/spec pairs).  What it misses runs before and after every merge.
require 'json'
require 'set'
require 'shellwords'

module QuickSelection
  ROOT = File.expand_path('..', __dir__)
  MAP_PATH = File.join(ROOT, 'spec', 'quick_map.json')
  TARGET = 0.95

  ALWAYS = %w[
    spec/spec_hygiene_spec.rb
    spec/warning_guard_spec.rb
    spec/quick_selection_spec.rb
    spec/lib/mb/sound/buffer_size_invariance_spec.rb
    spec/lib/mb/sound/buffer_size_invariance_synth_spec.rb
    spec/lib/mb/sound/take_spec.rb
    spec/lib/mb/sound/graph_sweep_spec.rb
    spec/lib/mb/sound/relation_fuzz_spec.rb
    spec/lib/mb/sound/graph_node/dsl_shadowing_spec.rb
    spec/lib/mb/sound/ui/gem_boundary_spec.rb
    spec/lib/mb/sound/ui/overlay_guard_spec.rb
    spec/valgrind/memcheck_selection_spec.rb
  ].freeze

  Selection = Struct.new(:specs, :reasons, :changed, :map, keyword_init: true)

  module_function

  def load_map(path = MAP_PATH)
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  end

  def spec_files
    Dir.chdir(ROOT) { Dir['spec/**/*_spec.rb'].sort }
  end

  # Top-level describe names of every spec file (constants or strings)
  def describes
    @describes ||= spec_files.to_h do |s|
      text = File.read(File.join(ROOT, s))
      [s, text.scan(/^\s*RSpec\.describe[ (]+([A-Z][\w:]*|'[^']*'|"[^"]*")/).flatten.map { |d| d.delete(%q('")) }]
    end
  end

  def camel(s) = s.split('_').map(&:capitalize).join

  # Spec files of the unit at +path+ (a lib/, bin/, or ext/ path)
  def direct(path, specs = spec_files)
    case path
    when %r{\Abin/(.+)\.rb\z}
      ["spec/bin/#{$1}_spec.rb"] & specs
    when %r{\Aext/mb/(sound/)?(fast_\w+)/}, %r{\Aext/mb/(sound/)?(fast_\w+)\z}
      ["spec/ext/mb/#{$1}#{$2}_spec.rb"] & specs
    when %r{\Alib/(.+)\.rb\z}
      rel = $1
      base = File.basename(rel)
      const = rel.split('/').map { |p| p == 'mb' ? 'MB' : camel(p) }.join('::')
      short = camel(base)
      specs.select do |s|
        sb = File.basename(s, '_spec.rb')
        s == "spec/lib/#{rel}_spec.rb" || sb == base || sb.start_with?("#{base}_") ||
          describes.fetch(s, []).any? { |d| d == const || d == short || d.end_with?("::#{short}") }
      end
    else
      []
    end
  end

  def git(*args) = Dir.chdir(ROOT) { IO.popen(['git', *args], &:read) }

  # Files changed since the merge-base of HEAD and +base+, including the
  # working tree and untracked files.
  def changed_files(base = nil)
    base = 'master-ai' if base.to_s.empty?
    mb = git('merge-base', 'HEAD', base).strip
    raise "spec:quick: no merge-base with #{base}" if mb.empty?

    (git('diff', '--name-only', mb).lines + git('ls-files', '--others', '--exclude-standard').lines).map(&:chomp).uniq
  end

  def select(base: nil, changed: nil, map: load_map)
    changed ||= changed_files(base)
    specs = spec_files
    reasons = Hash.new { |h, k| h[k] = [] }
    known = (map && map['specs_known'] || []).to_set
    (map && map['cover'] || []).each { |s| reasons[s] << :cover }
    ALWAYS.each { |s| reasons[s] << :always }
    changed.each do |f|
      if f.start_with?('spec/') && f.end_with?('_spec.rb')
        reasons[f] << :changed
      else
        direct(f, specs).each { |s| reasons[s] << :"unit #{f}" }
      end
    end
    specs.each { |s| reasons[s] << :new unless map.nil? || known.include?(s) }
    reasons.select! { |s, _| specs.include?(s) }
    Selection.new(specs: reasons.keys.sort, reasons: reasons, changed: changed, map: map)
  end

  def describe(sel, times: {})
    total = times.values.sum
    t = sel.specs.sum { |s| times[s] || 0 }
    counts = Hash.new(0)
    sel.reasons.each_value { |r| counts[r.first.to_s.start_with?('unit') ? :unit : r.first] += 1 }
    m = sel.map
    puts "spec:quick: #{sel.specs.length} of #{spec_files.length} spec files" \
         "#{total > 0 ? format(' (%.0f s of %.0f s of last measured example time, %.0f%%)', t, total, 100 * t / total) : ''}: " \
         "#{counts[:cover]} covering set, #{counts[:always]} always, #{counts[:unit]} changed units, #{counts[:changed]} changed specs, #{counts[:new]} newer than the map"
    if m
      puts "spec:quick: map from #{m['generated']} (#{m['sha']}): #{m['cover'].length} files reach #{(100 * m['target']).round}% of #{m['branches']} lib/ branches"
    else
      puts 'spec:quick: no spec/quick_map.json (rake spec:quick:map); running ALWAYS and the changed units only'
    end
    sel.reasons.select { |_, r| r.any? { |x| x.to_s.start_with?('unit') || x == :changed } }.each do |s, r|
      puts "  #{s}  <- #{r.map(&:to_s).map { |x| x.delete_prefix('unit ') }.uniq.join(', ')}"
    end
  end

  # Reads a per-file coverage directory (spec/support/per_file_coverage.rb)
  # and +times+ ({ spec file => seconds }) and returns the map: the cheapest
  # spec files reaching TARGET of the lib/ branches the suite reaches
  # (lazy greedy set cover, most new branches per second first).
  def build_map(cov_dir, times, target: TARGET)
    branches = Hash.new { |h, k| h[k] = Set.new }
    free = Set.new
    Dir[File.join(cov_dir, '*.json')].grep(%r{/\d+\.json\z}).each do |f|
      d = JSON.parse(File.read(f))
      d['baseline'].each { |p, c| c['b'].each { |k| free << "#{p}\0#{k}" } if p.start_with?('lib/') }
      d['files'].each do |spec, h|
        h.each { |p, c| c['b'].each { |k| branches[spec] << "#{p}\0#{k}" } if p.start_with?('lib/') }
      end
    end
    ids = {}
    masks = branches.to_h do |s, el|
      m = 0
      (el - free).each { |e| m |= 1 << (ids[e] ||= ids.size) }
      [s, m]
    end
    pop = ->(i) { i.zero? ? 0 : i.to_s(2).count('1') }
    score = ->(s, g) { g / [times[s] || 0.5, 0.05].max }
    cand = masks.map { |s, m| [score.(s, pop.(m)), s] }.sort_by { |sc, s| [-sc, s] }
    covered = 0
    n = 0
    order = []
    while n < target * ids.size && !cand.empty?
      _, s = cand.shift
      g = pop.(masks[s] & ~covered)
      sc = score.(s, g)
      if cand.empty? || sc >= cand.first[0]
        break if g.zero?

        covered |= masks[s]
        n += g
        order << s
      else
        cand.insert(cand.bsearch_index { |c, _| c < sc } || cand.length, [sc, s])
      end
    end
    {
      'about' => 'Covering set for rake spec:quick: the cheapest spec files reaching `target` of the lib/ branches the suite reaches (per-file coverage, spec/support/per_file_coverage.rb); `rake spec:quick:map` regenerates it.  See spec/quick_selection.rb.',
      'generated' => Time.now.strftime('%Y-%m-%d'),
      'sha' => git('rev-parse', '--short', 'HEAD').strip,
      'target' => target,
      'branches' => ids.size,
      'seconds' => order.sum { |s| times[s] || 0 }.round(1),
      'suite_seconds' => times.values.sum.round(1),
      'specs_known' => spec_files,
      'cover' => order.sort,
    }
  end
end
