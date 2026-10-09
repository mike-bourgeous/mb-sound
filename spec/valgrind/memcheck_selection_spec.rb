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
      expect(MemcheckSelection.header_users('ext/mb/sound/include/mb_svf.h')).to contain_exactly('fast_filter', 'fast_loop')
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

    it 'is due without a stamp' do
      expect(MemcheckSelection.full_status[0]).to eq(true)
    end

    it 'is not due right after a full run, and due after FULL_EVERY_DAYS' do
      stamp = MemcheckSelection.write_stamp
      expect(MemcheckSelection.ext_merges_since(stamp['commit'])).to eq(0)
      expect(MemcheckSelection.full_status[0]).to eq(false)
      later = Time.now + MemcheckSelection::FULL_EVERY_DAYS * 86400 + 1
      expect(MemcheckSelection.full_status(now: later)[0]).to eq(true)
    end

    it 'counts first-parent merges that changed ext/' do
      # 2d merges into master-ai, at least two of which changed ext/
      old = MemcheckSelection.git('rev-list', '--first-parent', '--merges', '-n', '20', 'HEAD').lines.last.strip
      expect(MemcheckSelection.ext_merges_since("#{old}^1")).to be >= 2
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

    it 'selects the users of a shared header' do
      sel = select('ext/mb/sound/include/mb_svf.h')
      expect(sel.extensions.keys).to eq(['fast_filter', 'fast_loop'])
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
      expect(sel.specs).to eq(['spec/lib/mb/sound/curve_spec.rb'])
    end

    it 'selects nothing for unrelated files' do
      sel = select('README.md', 'bin/songs/acid_song.rb', 'spec/lib/mb/sound/sequence_spec.rb')
      expect(sel.empty?).to eq(true)
      expect(sel.ignored.length).to eq(3)
    end

    it 'ignores changes to the selection tooling' do
      expect(select('spec/valgrind/memcheck_map.json', 'spec/valgrind/memcheck_selection.rb').empty?).to eq(true)
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
      files = MemcheckSelection.extensions.first(9).map { |e| "#{e.dir}/extconf.rb" }
      expect(select(*files).full?).to eq(true)
      expect(select(*files.first(8)).full?).to eq(false)
    end
  end

  describe '.rakefile_section' do
    it 'covers the memcheck section to the end of the file' do
      content = File.read(MemcheckSelection.path('Rakefile'))
      range = MemcheckSelection.rakefile_section(content)
      lines = content.lines
      expect(lines[range.first - 1]).to start_with('# Valgrind memcheck')
      expect(range.last).to eq(lines.length)
      expect(range).not_to cover(lines.index { |l| l.include?("ExtensionTask.new 'mb-fast_sound'") } + 1)
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
        "ext/mb/sound/fast_filter/depend: fast_filter.o lists ext/mb/sound/include/mb_envelope.h, which it doesn't include",
        'ext/mb/sound/fast_filter/depend: gone.o has no source file'
      )
    end
  end
end
