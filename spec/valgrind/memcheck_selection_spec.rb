require_relative 'memcheck_selection'

RSpec.describe(MemcheckSelection) do
  let(:map) { MemcheckSelection.load_map }
  let(:mapped) { MemcheckSelection.spec_extensions(map) }

  describe 'spec map' do
    it 'has at least one memcheck spec for every extension' do
      covered = mapped.values.flatten.uniq
      expect(MemcheckSelection.extension_names - covered).to eq([])
    end

    it 'lists only existing memcheck spec files' do
      expect(mapped.keys - MemcheckSelection.spec_files).to eq([])
    end

    it 'names only existing extensions' do
      expect(mapped.values.flatten.uniq - MemcheckSelection.extension_names).to eq([])
    end
  end

  describe '.extensions' do
    it 'finds every extension with the modules it defines' do
      exts = MemcheckSelection.extensions.to_h { |e| [e.name, e.modules] }
      expect(exts['fast_sound']).to eq(['FastSound'])
      expect(exts['fast_midi']).to eq(['FastMIDI'])
      expect(exts['fast_resample']).to eq(['FastResample'])
      expect(exts.keys).to include('fast_loop', 'fast_plan', 'fast_audio')
    end
  end

  describe '.header_users' do
    it 'finds the users of a shared header' do
      expect(MemcheckSelection.header_users('ext/mb/sound/include/mb_svf.h')).to contain_exactly('fast_filter', 'fast_loop', 'fast_plan')
    end

    it 'follows includes through other headers' do
      file = tmp_path('x.c')
      File.write(file, "#include <math.h>\n#include \"numo/narray.h\"\n  #  include \"mb_osc_shapes.h\"\n")
      expect(MemcheckSelection.includes(file).map { |f| MemcheckSelection.rel(f) }).to eq([
        'ext/mb/sound/include/mb_ext_helpers.h',
        'ext/mb/sound/include/mb_osc_shapes.h',
      ])
    end
  end

  describe 'full-run stamp' do
    before do
      allow(MemcheckSelection).to receive(:stamp_path).and_return(tmp_path('memcheck_full.stamp'))
    end

    it 'says full runs are manual without a stamp' do
      expect(MemcheckSelection.full_status).to start_with('No full memcheck recorded; full runs are manual')
    end

    it 'reports the last full run and says full runs are manual, however old' do
      stamp = MemcheckSelection.write_stamp
      expect(MemcheckSelection.ext_merges_since(stamp['commit'])).to eq(0)
      later = MemcheckSelection.full_status(now: Time.now + 365 * 86400)
      expect(later).to start_with("Last full memcheck #{stamp['commit'][0, 10]}")
      expect(later).to include('0 ext merges since', 'full runs are manual')
      expect(later).not_to match(/due/i)
    end

    it 'counts first-parent merges that changed ext/' do
      # A throwaway repository, so the count doesn't depend on how many of
      # master-ai's recent merges happened to touch ext/ (only one of the
      # last 20 did on 2026-10-17, which failed the old history-based check).
      repo = File.dirname(tmp_path('repo/x'))
      FileUtils.mkdir_p(repo)
      sh = ->(*args) {
        out, err, status = Open3.capture3(*args, chdir: repo)
        raise "#{args.join(' ')}: #{err}" unless status.success?
        out
      }
      commit = ->(path, text, message) {
        FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
        File.write(File.join(repo, path), text)
        sh.('git', 'add', path)
        sh.('git', 'commit', '-q', '-m', message)
      }
      merge = ->(branch) { sh.('git', 'merge', '-q', '--no-ff', '-m', "Merge #{branch}", branch) }

      sh.('git', 'init', '-q', '-b', 'main')
      sh.('git', 'config', 'user.email', 'spec@example.com')
      sh.('git', 'config', 'user.name', 'spec')
      commit.('ext/a.c', "1\n", 'base')

      # The stamped commit arrives on a side branch that changes ext/; its
      # own merge doesn't count
      sh.('git', 'checkout', '-q', '-b', 'stamped')
      commit.('ext/a.c', "2\n", 'stamped work')
      stamped = sh.('git', 'rev-parse', 'HEAD').strip
      sh.('git', 'checkout', '-q', 'main')
      merge.('stamped')

      { 'ext_one' => 'ext/b.c', 'lib_only' => 'lib/x.rb', 'ext_two' => 'ext/c.c' }.each do |branch, path|
        sh.('git', 'checkout', '-q', '-b', branch)
        commit.(path, "#{branch}\n", branch)
        sh.('git', 'checkout', '-q', 'main')
        merge.(branch)
      end

      stub_const('MemcheckSelection::ROOT', repo)
      expect(MemcheckSelection.ext_merges_since(stamped)).to eq(2)
    end
  end

  describe '.select' do
    def select(*files)
      MemcheckSelection.select(files: files, map: map)
    end

    it 'selects the specs of a changed extension' do
      sel = select('ext/mb/sound/fast_loudness/fast_loudness.c')
      expect(sel.full?).to eq(false)
      expect(sel.extensions.keys).to eq(['fast_loudness'])
      expect(sel.specs).to include('spec/lib/mb/sound/loudness_spec.rb')
      expect(sel.specs).not_to include('spec/ext/mb/sound/fast_audio_spec.rb')
    end

    it 'includes the ALWAYS specs in every selection that runs' do
      expect(select('ext/mb/sound/fast_loudness/fast_loudness.c').specs).to include(*MemcheckSelection::ALWAYS)
      expect(MemcheckSelection.spec_files).to include(*MemcheckSelection::ALWAYS)
    end

    it 'selects the users of a shared header' do
      sel = select('ext/mb/sound/include/mb_svf.h')
      expect(sel.extensions.keys).to eq(['fast_filter', 'fast_loop', 'fast_plan'])
      expect(sel.specs).to include('spec/lib/mb/sound/filter/svf_spec.rb', 'spec/ext/mb/sound/fast_loop_spec.rb')
    end

    it 'selects extensions named in a changed lib file' do
      sel = select('lib/mb/sound/loudness.rb')
      expect(sel.extensions.keys).to eq(['fast_loudness'])
    end

    it 'matches lib files on their changed lines when given' do
      sel = MemcheckSelection.select(
        files: ['lib/mb/sound/tone.rb'], map: map,
        changes: { 'lib/mb/sound/tone.rb' => "-    MB::Sound::FastSynth.feedback_sine(a)\n+    x = 1\n" }
      )
      expect(sel.extensions.keys).to eq(['fast_synth'])

      sel = MemcheckSelection.select(files: ['lib/mb/sound/tone.rb'], map: map, changes: { 'lib/mb/sound/tone.rb' => "+  # comment\n" })
      expect(sel.empty?).to eq(true)
    end

    it 'uses only the changed lines of a lib file in a git diff' do
      # c5c2867a (op-feedback) changed tone.rb, which names four extensions,
      # but its changed lines name only FastSynth and FastArithmetic
      text = MemcheckSelection.lib_change_text('lib/mb/sound/tone.rb', 'c5c2867a^1', 'c5c2867a', false)
      mods = text.scan(/\bFast[A-Z]\w*/).uniq.sort
      expect(mods).to include('FastSynth')
      expect(mods).not_to include('FastWavetable')
    end

    it 'selects a changed memcheck spec by itself' do
      sel = select('spec/lib/mb/sound/curve_spec.rb')
      expect(sel.extensions).to be_empty
      # (memcheck specs added since the map was recorded run in every
      # selective run until the map is refreshed)
      expect(sel.specs).to eq(['spec/lib/mb/sound/curve_spec.rb', *MemcheckSelection::ALWAYS, *sel.unmapped_specs].uniq.sort)
    end

    it 'selects nothing for unrelated files' do
      sel = select('README.md', 'bin/songs/acid_song.rb', 'spec/lib/mb/sound/sequence_spec.rb')
      expect(sel.empty?).to eq(true)
      expect(sel.ignored.length).to eq(3)
    end

    it 'ignores changes to the selection tooling' do
      expect(select('spec/valgrind/memcheck_map.json', 'spec/valgrind/memcheck_selection.rb', 'spec/valgrind/memcheck_parallel.rb').empty?).to eq(true)
    end

    it 'runs specs that are not in the map yet' do
      sel = MemcheckSelection.select(files: ['ext/mb/sound/fast_loudness/fast_loudness.c'], map: { 'specs' => {} })
      expect(sel.specs).to eq(MemcheckSelection.spec_files)
      expect(sel.full?).to eq(false)
    end

    [
      'spec/valgrind/ruby.supp',
      'spec/valgrind/gc_stress_calls.rb',
      'ext/mb/sound/include/mb_ext_helpers.h',
      '.ruby-version',
      'Rakefile',
    ].each do |f|
      it "runs everything for #{f}" do
        sel = select(f)
        expect(sel.full?).to eq(true)
        expect(sel.specs).to eq(MemcheckSelection.spec_files)
      end
    end

    it 'runs everything when more than half of the extensions are affected' do
      half = (MemcheckSelection.extension_names.length * MemcheckSelection::FULL_FRACTION).floor
      files = MemcheckSelection.extensions.first(half + 1).map { |e| "#{e.dir}/extconf.rb" }
      expect(select(*files).full?).to eq(true)
      expect(select(*files.first(half)).full?).to eq(false)
    end
  end

  describe '.rakefile_section' do
    it 'covers the memcheck section to its end marker' do
      content = File.read(MemcheckSelection.path('Rakefile'))
      range = MemcheckSelection.rakefile_section(content)
      lines = content.lines
      expect(lines[range.first - 1]).to start_with('# Valgrind memcheck')
      expect(lines[range.last]).to start_with('# (end of the memcheck section') # (the line after the range)
      expect(range).to cover(lines.index { |l| l.include?("namespace :memcheck do") } + 1)
      expect(range).not_to cover(lines.index { |l| l.include?('namespace :golden do') } + 1)
      expect(range).not_to cover(lines.index { |l| l.include?("ExtensionTask.new 'mb-fast_sound'") } + 1)
    end
  end

  describe 'ext/ structure' do
    let(:current) { MemcheckSelection.structure }

    it 'is known to the map (else run `rake memcheck:map` and commit the map)' do
      problems = MemcheckSelection.structure_problems(map, current)
      expect(problems).to eq([]), MemcheckSelection.structure_message(problems)
    end

    it 'lists sources, modules, includes, and depend entries' do
      fast_filter = current.fetch('fast_filter')
      expect(fast_filter['sources']).to include('fast_filter.c')
      expect(fast_filter['modules']).to eq(['FastFilter'])
      expect(fast_filter['includes']).to include('ext/mb/sound/include/mb_svf.h', 'ext/mb/sound/include/mb_ext_helpers.h')
      expect(fast_filter['depend'].fetch('fast_filter.o')).to include('ext/mb/sound/include/mb_svf.h')
    end

    def problems_after
      recorded = JSON.parse(JSON.generate(current))
      yield recorded
      MemcheckSelection.structure_problems({ 'structure' => recorded }, current)
    end

    it 'reports new and removed extensions, sources, modules, and includes' do
      expect(problems_after { |r| r.delete('fast_lofi') }).to eq(['new extension fast_lofi'])
      expect(problems_after { |r| r['fast_gone'] = r['fast_lofi'] }).to eq(['removed extension fast_gone'])
      expect(problems_after { |r| r['fast_sampler']['sources'] -= ['granular.c'] }).to eq(['fast_sampler: new sources granular.c'])
      expect(problems_after { |r| r['fast_lofi']['sources'] += ['old.c'] }).to eq(['fast_lofi: removed sources old.c'])
      expect(problems_after { |r| r['fast_filter']['modules'] = [] }).to eq(['fast_filter: new modules FastFilter'])
      expect(problems_after { |r| r['fast_filter']['includes'] -= ['ext/mb/sound/include/mb_svf.h'] }).to eq(
        ['fast_filter: new includes ext/mb/sound/include/mb_svf.h']
      )
    end

    it 'reports changed depend files' do
      expect(problems_after { |r| r['fast_filter']['depend']['fast_filter.o'].pop }).to eq(['fast_filter: depend changed'])
    end

    it 'asks for a refresh when the map has no structure, naming the command' do
      problems = MemcheckSelection.structure_problems({ 'specs' => {} }, current)
      expect(problems.length).to eq(1)
      expect(MemcheckSelection.structure_message(problems)).to include(MemcheckSelection::MAP_COMMAND)
      expect(MemcheckSelection.structure_message([])).to eq(nil)
    end
  end

  describe 'depend files' do
    it 'list every header each extension object includes, and nothing else' do
      expect(MemcheckSelection.depend_problems).to eq([])
    end

    it 'reports missing and stale entries' do
      ext = MemcheckSelection.extension('fast_filter')
      allow(MemcheckSelection).to receive(:parse_depend).and_return(
        'fast_filter.o' => ['ext/mb/sound/include/mb_ext_helpers.h', 'ext/mb/sound/include/mb_envelope.h'],
        'gone.o' => []
      )
      expect(MemcheckSelection.depend_problems_for(ext)).to contain_exactly(
        'ext/mb/sound/fast_filter/depend: fast_filter.o is missing ext/mb/sound/include/mb_svf.h',
        'ext/mb/sound/fast_filter/depend: fast_filter.o is missing ext/mb/sound/include/mb_four_pole.h',
        'ext/mb/sound/fast_filter/depend: fast_filter.o is missing ext/mb/sound/include/mb_four_pole_tuning.h',
        "ext/mb/sound/fast_filter/depend: fast_filter.o lists ext/mb/sound/include/mb_envelope.h, which it doesn't include",
        'ext/mb/sound/fast_filter/depend: gone.o has no source file'
      )
    end
  end
end
