# Selective Valgrind memcheck (`rake memcheck:changed`), the full-run
# stamp, and the depend file check (`rake depend:check`).  Loaded by the
# Rakefile, the map recorder, and spec/valgrind/memcheck_selection_spec.rb;
# plain Ruby (no mb-sound), so rake doesn't load the library.
#
# Selection: changed files -> affected extensions -> memcheck specs.
#
# - ext/**/<ext>/** (sources, extconf.rb, depend) -> that extension (also
#   the gems' extensions, gems/*/ext/**/<ext>/**: mb-term's fast_term)
# - ext/mb/sound/include/*.h (and gems/*/ext/**/include/*.h) -> every
#   extension whose sources include it, directly or through other headers
#   (scanned at run time; depend files aren't trusted)
# - lib/**/*.rb (and gems/*/lib/**/*.rb) whose changed lines (added or removed) mention a module an
#   extension defines (`FastSynth`, word match; the whole file when it is
#   new or deleted) -> that extension
# - a changed spec in SPECS -> that spec
# - ALWAYS (the graph sweep) joins every selection that runs anything
# - FULL_TRIGGERS, a changed Rakefile memcheck section, ruby_memcheck in
#   Gemfile.lock, a new extension, or more than FULL_FRACTION of the
#   extensions -> the full list
#
# Extensions -> specs comes from spec/valgrind/memcheck_map.json, recorded
# natively by `rake memcheck:map` (MEMCHECK_MAP=1 rspec with
# memcheck_map_recorder.rb: which extension methods each spec file calls).
# Specs in SPECS but not in the map run in every selective run until the
# map is refreshed.
#
# The map also records the structure of ext/ it was made against (each
# extension's source files, Fast* modules, resolved #includes, and depend
# entries; .structure).  A branch that adds a source, header, extension,
# module, or include, or changes a depend file, refreshes the map in that
# branch (`rake memcheck:map`, ~5 min natively) and commits it: the guard
# spec in memcheck_selection_spec.rb (normal suite) and `memcheck:changed`
# fail on .structure_problems, so a stale map can't silently under-select.
# Edits inside existing files need no refresh.
#
# The full list (`rake memcheck`, or FULL=1) is manual: before a public
# release, or when hunting a leak (maintainer decision 2026-10-18).
require 'fileutils'
require 'json'
require 'open3'
require 'set'
require 'time'

module MemcheckSelection
  ROOT = File.expand_path('../..', __dir__)

  # The memcheck spec list (globs relative to ROOT); `rake memcheck` runs
  # all of it.
  SPECS = [
    # Direct tests of every extension function
    'spec/ext/**/*_spec.rb',
    'spec/lib/mb/fast_sound_spec.rb',

    # Ruby classes whose inner loops are in C (cross-checks against Ruby
    # reference implementations, odd buffer sizes, wraparound)
    'spec/lib/mb/sound/delay_line_spec.rb',          # FastDelay.read/feedback
    'spec/lib/mb/sound/graph_node/multitap_delay_spec.rb',
    'spec/lib/mb/sound/filter/delay_spec.rb',
    'spec/lib/mb/sound/tone_phasor_spec.rb',         # FastSound.phasor/oscillate
    'spec/lib/mb/sound/tone_waveforms_spec.rb',      # FastSound.osc/oscillate, FastSynth.oscillate_bl
    'spec/lib/mb/sound/generation_methods_spec.rb',  # FastSound noise (splitmix64 state)
    'spec/lib/mb/sound/band_limit_spec.rb',          # FastSynth.oscillate_bl/blit/oscillate_sync
    'spec/lib/mb/sound/tone_feedback_spec.rb',       # FastSynth.feedback_sine through Tone (resets, nodes)
    'spec/lib/mb/sound/tone_gain_spec.rb',           # FastArithmetic.scale through Tone#gain
    'spec/lib/mb/sound/shaper_spec.rb',              # FastClip.shape
    'spec/lib/mb/sound/graph_node/curve_shaper_spec.rb', # FastClip.shape_curve
    'spec/lib/mb/sound/curve_spec.rb',               # FastClip.curve_lookup
    'spec/lib/mb/sound/envelope_spec.rb',            # FastEnvelope.process
    'spec/lib/mb/sound/envelope_segments_spec.rb',   # FastEnvelope.process (segment lists, loops)
    'spec/lib/mb/sound/notes_smoothing_spec.rb',     # FastControl.smooth (controller smoothing)
    'spec/lib/mb/sound/filter/four_pole_spec.rb',    # FastFilter.four_pole
    'spec/lib/mb/sound/filter/diode_ladder_spec.rb', # FastFilter.diode_ladder
    'spec/lib/mb/sound/filter/svf_spec.rb',          # FastFilter.svf
    'spec/lib/mb/sound/graph_node/formant_spec.rb',  # FastFilter.formant through Formant
    'spec/lib/mb/sound/graph_node/resonator_spec.rb', # FastResonator.ping
    'spec/lib/mb/sound/graph_node/decimator_spec.rb', # FastLofi.decimate through Decimator
    'spec/lib/mb/sound/graph_node/modal_resonator_spec.rb', # FastResonator.modes through ModalResonator
    'spec/lib/mb/sound/graph_node/texture_spec.rb',  # FastTexture.dust/drift through Dust and Drift
    'spec/lib/mb/sound/sampler_spec.rb',             # FastSampler.play through SamplerVoice (synths, chops, SFZ)
    'spec/lib/mb/sound/granular_spec.rb',            # FastSampler.grains through Grains (scans, voices, buffer sizes)
    'spec/lib/mb/sound/graph_node/dynamics_spec.rb', # FastDynamics.compand/limit/crossover through the nodes
    'spec/lib/mb/sound/graph_node/reverb_spec.rb',   # FastReverb::Network through Reverb (modulation, loop processing, graph mode)
    'spec/lib/mb/sound/loudness_spec.rb',            # FastLoudness.true_peak
    'spec/lib/mb/sound/wavetable_spec.rb',           # FastWavetable
    'spec/lib/mb/sound/graph_node/wavetable_spec.rb',
    'spec/lib/mb/sound/tone_wavetable_spec.rb',      # FastWavetable through Tone (sync, resets, sample mode)
    'spec/lib/mb/sound/graph_node/harmonic_table_spec.rb',
    'spec/lib/mb/sound/filter/biquad_spec.rb',       # FastSound.biquad*
    'spec/lib/mb/sound/filter/cookbook_spec.rb',     # FastSound.cookbook, dynamic_biquad
    'spec/lib/mb/sound/graph_node/resample_spec.rb', # FastResample (libsamplerate)
    'spec/lib/mb/sound/graph_node/constant_spec.rb', # FastSound.smootherstep_buf
    'spec/lib/mb/sound/device_output_spec.rb',       # FastAudio::Playback
    'spec/lib/mb/sound/device_input_spec.rb',        # FastAudio::Capture
    'spec/lib/mb/sound/midi/input_spec.rb',          # MIDI::Input on JACK and RtMidi (with a JACK dummy server)
    'spec/lib/mb/sound/midi/live_source_spec.rb',    # Playback#jack_clock (with a JACK dummy server)
    'spec/lib/mb/sound/jack_spec.rb',                # DeviceOutput/Input and MIDI on one JACK client
    'spec/lib/mb/sound/plan/*_spec.rb',              # FastPlan.run through planned regions (tones, resets, fallbacks, events, envelopes, smoothing)
    'spec/lib/mb/sound/notes_fast_paths_spec.rb',    # FastPlan.run through Synth lanes' plans (envelopes, events, skipped lanes)
    'spec/lib/mb/sound/graph_node/feedback_loop_spec.rb', # FastLoop.run (plan/loop_spec.rb runs with the plan specs)

    # Every node and filter type, planned and unplanned (memcheck light)
    'spec/lib/mb/sound/graph_sweep_spec.rb',

    # mb-term's native grid against its Ruby Cells, and its C VT against
    # RubyVT (run here under mb-sound's spec_helper; also in the gem's own
    # specs)
    'gems/mb-term/spec/native_spec.rb',
    'gems/mb-term/spec/vt_native_spec.rb',
  ].freeze

  # Specs every selective run includes (when it runs anything): the graph
  # sweep reaches combinations of C paths the per-extension specs don't.
  ALWAYS = ['spec/lib/mb/sound/graph_sweep_spec.rb'].freeze

  MAP_PATH = 'spec/valgrind/memcheck_map.json'
  INCLUDE_DIR = 'ext/mb/sound/include'

  # Every shared include directory: mb-sound's and the gems' (mb-term's
  # mb_term_grid.h, which fast_ui includes too).
  INCLUDE_DIRS = [INCLUDE_DIR, *Dir.glob('gems/*/ext/**/include', base: ROOT).sort].freeze

  # Where extensions live: mb-sound's ext/ and each gem's.
  EXT_ROOTS = ['ext', *Dir.glob('gems/*/ext', base: ROOT).sort].freeze

  # Changes to these run the full list: they change what memcheck checks
  # (suppressions, the GC.stress wrapper, the Ruby) or reach nearly every
  # extension (the shared helpers).
  FULL_TRIGGERS = [
    'spec/valgrind/*',
    '.ruby-version',
    "#{INCLUDE_DIR}/mb_ext_helpers.h",
  ].freeze

  # The selection and runner tooling itself doesn't change what memcheck
  # checks (the parallel runner's plumbing has its own spec with a stand-in
  # Valgrind in the normal suite).
  TOOL_FILES = %w[
    spec/valgrind/README
    spec/valgrind/memcheck_parallel.rb
    spec/valgrind/memcheck_parallel_spec.rb
    spec/valgrind/memcheck_selection.rb
    spec/valgrind/memcheck_selection_spec.rb
    spec/valgrind/memcheck_map_recorder.rb
    spec/valgrind/memcheck_map.json
  ].freeze

  # More than this fraction of the extensions affected runs the full list.
  FULL_FRACTION = 0.5

  # Full runs are manual (maintainer decision 2026-10-18): a pre-release
  # step, or a deliberate choice when hunting a hard-to-find leak.  No
  # recorded full run since selective memcheck began (2026-10-09) found a
  # Valgrind error the selective runs missed, so nothing makes one "due" by
  # merge count or age; the stamp only records the last one.  What keeps
  # selective runs honest instead is a current map: a branch that changes
  # the structure of ext/ refreshes it (see .structure_problems).
  MAP_COMMAND = 'bundle exec rake -f Rakefile memcheck:map'

  Extension = Struct.new(:name, :dir, :modules, keyword_init: true)

  Selection = Struct.new(
    :base, :to, :files, :full, :full_reasons, :extensions, :specs,
    :unmapped_specs, :changed_specs, :ignored, keyword_init: true
  ) do
    def full?
      full
    end

    def empty?
      !full && specs.empty?
    end
  end

  module_function

  def path(rel)
    File.join(ROOT, rel)
  end

  def rel(abs)
    abs.delete_prefix("#{ROOT}/")
  end

  # Every extension (a directory with an extconf.rb), with the Ruby modules
  # and classes its C code defines under MB/MB::Sound (FastSound, FastMIDI,
  # ...).
  def extensions
    @extensions ||= EXT_ROOTS.flat_map { |r| Dir[path("#{r}/**/extconf.rb")] }.sort.map { |f|
      dir = File.dirname(f)
      mods = source_files(dir).flat_map { |s|
        File.read(s, encoding: 'binary').scan(/rb_define_(?:module|class)(?:_under)?\([^;]*?"(Fast\w*)"/).flatten
      }.uniq.sort
      Extension.new(name: File.basename(dir), dir: rel(dir), modules: mods)
    }.freeze
  end

  def extension_names
    extensions.map(&:name)
  end

  # {'FastSynth' => 'fast_synth', ...}
  def module_extensions
    @module_extensions ||= extensions.each_with_object({}) { |e, h| e.modules.each { |m| h[m] = e.name } }.freeze
  end

  # The Fast* modules behind each MB::Sound::Kernels function name
  # (kernels-1: call sites write Kernels.svf, not FastFilter.svf), found in
  # lib/ without loading it: each `register :name, ...` statement's Fast*
  # modules (its c: and covers:), and for a loop registering every method of
  # a mirror module (`register m, c: FastX.method(m)`), every method its
  # file defines.  {'svf' => ['FastFilter'], 'copy' => ['FastArithmetic'], ...}
  def kernel_modules
    @kernel_modules ||= begin
      map = Hash.new { |h, k| h[k] = [] }
      Dir[path('lib/**/*.rb')].sort.each do |f|
        text = File.read(f).gsub(/^\s*#.*$/, '') # (code only: the registry's comments show examples)
        next unless text.include?('register')

        text.scan(/\bregister\s+:(\w+)(.*?)(?=^\s*(?:Kernels\.)?register\s|^\s*end\b|\z)/m) do |name, rest|
          map[name] |= rest.scan(/\b(Fast[A-Z]\w*)\b/).flatten
        end
        text.scan(/\bregister\s+(\w+),\s*c:\s*(Fast[A-Z]\w*)\.method\(\1\)/).each do |_, mod|
          text.scan(/^\s*def\s+(\w+)/).flatten.each { |m| map[m] |= [mod] }
        end
      end
      map.reject { |_, v| v.empty? }.freeze
    end
  end

  def source_files(dir)
    Dir[File.join(dir, '*.{c,cpp,h,hpp}')].sort
  end

  # Quoted #includes of a file resolved to files in this repository (the
  # including file's directory first, then the shared include directory),
  # transitively.  Unresolved names (system headers, numo) are skipped.
  def includes(file)
    @includes ||= {}
    @includes[file] ||= begin
      seen = Set.new
      queue = [file]
      until queue.empty?
        f = queue.shift
        direct_includes(f).each do |inc|
          next if seen.include?(inc)

          seen << inc
          queue << inc
        end
      end
      seen.to_a.sort.freeze
    end
  end

  def direct_includes(file)
    @direct ||= {}
    @direct[file] ||= File.read(file, encoding: 'binary').scan(/^[ \t]*#[ \t]*include[ \t]+"([^"]+)"/).flatten.filter_map { |name|
      [File.dirname(file), *INCLUDE_DIRS.map { |d| path(d) }].map { |d| File.expand_path(name, d) }.find { |p| File.file?(p) }
    }.uniq
  end

  # Shared headers (relative paths) an extension's sources include,
  # directly or through other headers.
  def shared_headers(ext)
    ext = extension(ext)
    source_files(path(ext.dir)).flat_map { |s| includes(s) }.uniq
      .select { |f| INCLUDE_DIRS.any? { |d| f.start_with?(path(d) + '/') } }.map { |f| rel(f) }.sort
  end

  # Extensions whose sources include +header+ (a relative path).
  def header_users(header)
    extensions.select { |e| shared_headers(e).include?(header) }.map(&:name)
  end

  def extension(name)
    return name if name.is_a?(Extension)

    extensions.find { |e| e.name == name } || raise(ArgumentError, "No extension #{name}")
  end

  # The memcheck spec files (relative paths).
  def spec_files
    SPECS.flat_map { |g| Dir.glob(g, base: ROOT) }.uniq.sort
  end

  def load_map(file = path(MAP_PATH))
    return { 'specs' => {} } unless File.file?(file)

    JSON.parse(File.read(file))
  end

  # {'spec/x_spec.rb' => ['fast_synth', ...]}
  def spec_extensions(map = load_map)
    map.fetch('specs').transform_values(&:keys)
  end

  # Extension guessed from a spec's file name (spec/ext/mb/sound/fast_audio_jack_spec.rb
  # -> fast_audio), for specs whose calls happen in subprocesses.
  def static_extension(spec)
    return nil unless spec.start_with?('spec/ext/')

    base = File.basename(spec, '_spec.rb')
    extension_names.select { |n| base == n || base.start_with?("#{n}_") }.max_by(&:length)
  end

  # --- Changed files -------------------------------------------------------

  def git(*args, allow_fail: false)
    out, err, status = Open3.capture3('git', *args, chdir: ROOT)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success? || allow_fail

    status.success? ? out : nil
  end

  # The merge-base of HEAD and +base+ (default master-ai).
  def resolve_base(base = nil)
    base = 'master-ai' if base.to_s.empty?
    git('merge-base', 'HEAD', base).strip
  end

  # Files changed since +base+ (a commit): up to +to+ (a commit), or the
  # working tree including uncommitted and untracked files.
  def changed_files(base, to = nil)
    files = git('diff', '--name-only', '--no-renames', base, *to).lines.map(&:chomp)
    files += git('ls-files', '--others', '--exclude-standard').lines.map(&:chomp) unless to
    files.uniq.sort
  end

  # Extension names in a commit (nil: the working tree).
  def extension_names_at(commit)
    return extension_names unless commit

    git('ls-tree', '-r', '--name-only', commit, *EXT_ROOTS).lines.grep(%r{/extconf\.rb$}).map { |l| File.basename(File.dirname(l.chomp)) }
  end

  # Line numbers (new side) changed in +file+ between base and to.
  def changed_lines(base, to, file)
    git('diff', '-U0', '--no-renames', base, *to, '--', file).scan(/^@@ -\S+ \+(\d+)(?:,(\d+))? @@/).flat_map { |start, count|
      start = start.to_i
      count = (count || 1).to_i
      count == 0 ? [start, start + 1] : (start...(start + count)).to_a
    }
  end

  def file_content(file, to)
    to ? git('show', "#{to}:#{file}", allow_fail: true) : (File.file?(path(file)) ? File.read(path(file)) : nil)
  end

  # Text a changed lib file is matched against for Fast* module names: the
  # added and removed lines of its diff, or the whole file when it is new
  # (or deleted).
  def lib_change_text(f, base, to, synthetic, changes = {})
    return changes[f] if changes.key?(f)
    return file_content(f, to) if synthetic

    old = git('cat-file', '-e', "#{base}:#{f}", allow_fail: true)
    new = to ? git('cat-file', '-e', "#{to}:#{f}", allow_fail: true) : File.file?(path(f))
    return file_content(f, to) unless old
    return git('show', "#{base}:#{f}") unless new

    git('diff', '-U0', '--no-renames', base, *to, '--', f).lines
      .select { |l| l =~ /^[-+]/ && !l.start_with?('+++', '---') }.join
  end

  # Line range of the memcheck section of the Rakefile (from its heading
  # comment to its end marker, else the end of the file; the spec, plan,
  # and golden tasks after the marker don't make memcheck runs full).
  def rakefile_section(content)
    lines = content.to_s.lines
    first = lines.index { |l| l.start_with?('# Valgrind memcheck') }
    return nil unless first

    last = lines.index { |l| l.start_with?('# (end of the memcheck section') }
    (first + 1)..(last && last > first ? last : lines.length)
  end

  # --- Selection -----------------------------------------------------------

  # Selects memcheck specs for the changes since +base+ (default: the
  # merge-base with master-ai).  +files+ replaces the git diff (synthetic
  # selections; a Rakefile listed there counts as a memcheck section change).
  # +changes+ ({file => changed lines}) stands in for the git diff of
  # lib files in synthetic selections (files without an entry are matched
  # whole, as new files are).
  def select(base: nil, to: nil, files: nil, map: load_map, changes: {})
    synthetic = !files.nil?
    unless synthetic
      base = resolve_base(base)
      files = changed_files(base, to)
    end

    full_reasons = []
    exts = Hash.new { |h, k| h[k] = [] }
    changed_specs = []
    ignored = []
    list = spec_files
    names = extension_names
    ext_dirs = extensions.to_h { |e| [e.name, e.dir + '/'] }

    files.each do |f|
      next if TOOL_FILES.include?(f)

      owner = ext_dirs.find { |_, d| f.start_with?(d) }&.first

      if FULL_TRIGGERS.any? { |t| File.fnmatch?(t, f, File::FNM_PATHNAME) }
        full_reasons << f
      elsif f == 'Rakefile'
        if synthetic
          full_reasons << 'Rakefile'
        else
          range = rakefile_section(file_content('Rakefile', to))
          full_reasons << 'Rakefile memcheck section' if range && changed_lines(base, to, f).any? { |l| range.cover?(l) }
        end
      elsif f == 'Gemfile.lock'
        if synthetic
          full_reasons << 'Gemfile.lock'
        elsif git('diff', '-U0', base, *to, '--', f).lines.any? { |l| l =~ /^[-+](?![-+])/ && l.include?('ruby_memcheck') }
          full_reasons << 'Gemfile.lock (ruby_memcheck)'
        end
      elsif INCLUDE_DIRS.any? { |d| f.start_with?("#{d}/") }
        users = header_users(f)
        users.each { |n| exts[n] << "#{f} (included)" }
        ignored << f if users.empty?
      elsif owner
        exts[owner] << f
      elsif EXT_ROOTS.any? { |r| f.start_with?("#{r}/") }
        ignored << f
      elsif (f.start_with?('lib/') || f.match?(%r{\Agems/[^/]+/lib/})) && f.end_with?('.rb')
        content = lib_change_text(f, base, to, synthetic, changes)
        mods = content.to_s.scan(/\b(Fast[A-Z]\w*)\b/).flatten.uniq & module_extensions.keys
        mods.each { |m| exts[module_extensions[m]] << "#{f} (#{m})" }
        # (and kernel calls through MB::Sound::Kernels: Kernels.svf -> FastFilter)
        kernel_mods = content.to_s.scan(/\bKernels\.(\w+)/).flatten.uniq.flat_map { |k| (kernel_modules[k] || []).map { |m| [k, m] } }
        kernel_mods.each { |k, m| exts[module_extensions[m]] << "#{f} (Kernels.#{k}: #{m})" if module_extensions[m] }
        ignored << f if mods.empty? && kernel_mods.empty?
      elsif list.include?(f)
        changed_specs << f
      else
        ignored << f
      end
    end

    unless synthetic
      (extension_names_at(to) - extension_names_at(base)).each { |n| full_reasons << "new extension #{n}" }
    end

    if exts.length > names.length * FULL_FRACTION
      full_reasons << "#{exts.length} of #{names.length} extensions affected"
    end

    mapped = spec_extensions(map)
    unmapped = list - mapped.keys
    full = !full_reasons.empty?
    specs = full ? list : list.select { |s|
      changed_specs.include?(s) || unmapped.include?(s) || (mapped[s] & exts.keys).any?
    }
    if !full && exts.empty? && changed_specs.empty?
      specs = []
    elsif !full
      specs = (specs | (ALWAYS & list)).sort
    end

    Selection.new(
      base: base, to: to, files: files, full: full, full_reasons: full_reasons.uniq,
      extensions: exts.transform_values(&:uniq).sort.to_h, specs: specs,
      unmapped_specs: unmapped, changed_specs: changed_specs, ignored: ignored
    )
  end

  def describe(sel, io = $stdout)
    from = sel.base ? sel.base[0, 10] : 'synthetic'
    io.puts "memcheck:changed: #{sel.files.length} changed files since #{from}#{sel.to ? " up to #{sel.to}" : ' (working tree)'}"
    sel.extensions.each do |name, why|
      io.puts "  #{name}: #{why.first(4).join(', ')}#{why.length > 4 ? ", ... (#{why.length})" : ''}"
    end
    io.puts "  changed memcheck specs: #{sel.changed_specs.join(' ')}" unless sel.changed_specs.empty?
    io.puts "  not memcheck-related: #{sel.ignored.length} files" unless sel.ignored.empty?
    if sel.full?
      io.puts "FULL run (#{sel.full_reasons.join('; ')}): #{sel.specs.length} spec files"
    elsif sel.empty?
      io.puts 'No extension changes: nothing to check'
    else
      io.puts "Selected #{sel.specs.length} of #{spec_files.length} spec files:"
      sel.specs.each { |s| io.puts "  #{s}#{sel.unmapped_specs.include?(s) ? ' (not in the map yet)' : ALWAYS.include?(s) ? ' (always)' : ''}" }
    end
  end

  # --- Full-run stamp ------------------------------------------------------

  # In the main checkout's tmp/, shared by every worktree.
  def stamp_path
    common = git('rev-parse', '--path-format=absolute', '--git-common-dir').strip
    File.join(File.dirname(common), 'tmp', 'memcheck_full.stamp')
  end

  def read_stamp
    JSON.parse(File.read(stamp_path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def write_stamp
    data = {
      'commit' => git('rev-parse', 'HEAD').strip,
      'branch' => git('rev-parse', '--abbrev-ref', 'HEAD').strip,
      'date' => Time.now.utc.iso8601,
      'dirty' => !git('status', '--porcelain', '--untracked-files=no').strip.empty?,
    }
    FileUtils.mkdir_p(File.dirname(stamp_path))
    File.write(stamp_path, JSON.pretty_generate(data) + "\n")
    data
  end

  # Merges into HEAD (first-parent history) since the stamped commit that
  # changed ext/, not counting the merge that brought in the checked commit.
  #
  # Ancestry comes from one --ancestry-path listing (the commits between
  # +sha+ and HEAD that descend from +sha+) rather than a `git merge-base
  # --is-ancestor` per merge, which took ~140 ms each in this repository.
  def ext_merges_since(sha)
    return nil unless git('cat-file', '-e', "#{sha}^{commit}", allow_fail: true)

    sha = git('rev-parse', "#{sha}^{commit}").strip
    descendants = git('rev-list', '--ancestry-path', "#{sha}..HEAD").lines.map(&:chomp).to_set << sha
    git('rev-list', '--first-parent', '--merges', '--parents', "#{sha}..HEAD").lines.count { |line|
      m, first, second = line.split
      !git('diff', '--quiet', first, m, '--', 'ext', allow_fail: true) &&
        !(descendants.include?(second) && !descendants.include?(first))
    }
  end

  # A line about the last recorded full run (full runs are manual; nothing
  # makes one due).
  def full_status(now: Time.now)
    stamp = read_stamp
    manual = 'full runs are manual (before a public release, or to hunt a leak: `rake memcheck` or FULL=1 rake memcheck:changed)'
    return "No full memcheck recorded; #{manual}" unless stamp

    days = (now - Time.parse(stamp['date'])) / 86400.0
    merges = ext_merges_since(stamp['commit'])
    format("Last full memcheck %s on %s (%.1f days ago, %s ext merges since); %s",
           stamp['commit'][0, 10], stamp['branch'], days, merges.nil? ? 'unknown' : merges, manual)
  end

  # --- ext/ structure the map was recorded against -----------------------

  # {'fast_synth' => {'dir' =>, 'sources' => [basenames], 'modules' =>
  # [Fast*], 'includes' => [repository files any source includes,
  # transitively], 'depend' => {'x.o' => [files]}}, ...}
  def structure
    extensions.to_h { |e|
      dir = path(e.dir)
      sources = source_files(dir)
      [e.name, {
        'dir' => e.dir,
        'sources' => sources.map { |f| File.basename(f) },
        'modules' => e.modules,
        'includes' => sources.flat_map { |f| includes(f) }.map { |f| rel(f) }.uniq.sort,
        'depend' => parse_depend(File.join(dir, 'depend')).transform_values { |v| v.uniq.sort }.sort.to_h,
      }]
    }.sort.to_h
  end

  # Ways the current ext/ differs from the structure the map recorded, one
  # line each; [] when the map is current.
  def structure_problems(map = load_map, current = structure)
    recorded = map['structure']
    return ["#{MAP_PATH} has no ext/ structure (recorded before 2026-10-18)"] unless recorded.is_a?(Hash)

    problems = []
    (current.keys - recorded.keys).each { |n| problems << "new extension #{n}" }
    (recorded.keys - current.keys).each { |n| problems << "removed extension #{n}" }
    (current.keys & recorded.keys).each do |n|
      now = current[n]
      was = recorded[n]
      %w[sources modules includes].each do |k|
        added = now[k] - Array(was[k])
        removed = Array(was[k]) - now[k]
        problems << "#{n}: new #{k} #{added.join(', ')}" unless added.empty?
        problems << "#{n}: removed #{k} #{removed.join(', ')}" unless removed.empty?
      end
      problems << "#{n}: depend changed" unless now['depend'] == (was['depend'] || {})
    end
    problems
  end

  # The message for a stale map, or nil.
  def structure_message(problems = structure_problems)
    return nil if problems.empty?

    "#{MAP_PATH} doesn't know the current ext/ structure:\n  #{problems.join("\n  ")}\n" \
      "Refresh it in this branch and commit it (natively, ~5 min):\n  #{MAP_COMMAND}"
  end

  # --- depend files ---------------------------------------------------------

  # Problems with each extension's depend file: headers its objects include
  # (local or shared, transitively) that aren't listed, and listed files
  # that aren't included.  [] when all match.
  def depend_problems
    extensions.flat_map { |e| depend_problems_for(e) }
  end

  def depend_problems_for(ext)
    ext = extension(ext)
    dir = path(ext.dir)
    listed = parse_depend(File.join(dir, 'depend'))
    problems = []
    Dir[File.join(dir, '*.{c,cpp}')].sort.each do |src|
      obj = File.basename(src).sub(/\.\w+\z/, '.o')
      expected = includes(src).map { |f| rel(f) }
      have = (listed.delete(obj) || []).reject { |f| f == rel(src) }
      (expected - have).each { |f| problems << "#{ext.dir}/depend: #{obj} is missing #{f}" }
      (have - expected).each { |f| problems << "#{ext.dir}/depend: #{obj} lists #{f}, which it doesn't include" }
    end
    listed.each_key { |obj| problems << "#{ext.dir}/depend: #{obj} has no source file" }
    problems
  end

  # {'x.o' => ['ext/.../y.h', ...]} with paths relative to ROOT.
  def parse_depend(file)
    return {} unless File.file?(file)

    dir = File.dirname(file)
    File.read(file).gsub("\\\n", ' ').lines.each_with_object({}) { |line, h|
      next unless line =~ /\A\s*([^\s:#]+)\s*:(.*)/

      obj = $1
      deps = $2.split.map { |d| rel(File.expand_path(d.sub('$(srcdir)/', ''), dir)) }
      (h[obj] ||= []).concat(deps)
    }
  end
end
