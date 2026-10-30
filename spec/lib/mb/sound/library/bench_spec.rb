require 'json'
require 'open3'
require 'tmpdir'

# Listening Bench sets of library presets (audition-1; design/notes/library.md,
# "Bench sets"): selection, materials, loudness matching, the set directory
# build_manifest.py reads, and reading the maintainer's notes back.
RSpec.describe MB::Sound::Library::Bench do
  let(:bench) { MB::Sound::Library::Bench }
  let(:index) { MB::Sound::Library.index }

  def entry(family, name) = index.entries(family: family).find { |e| e.name == name }

  describe '.select' do
    it 'takes families, kinds, head paths, family.name, entry names, and find queries' do
      expect(bench.select(:chorus)[0].map(&:name)).to eq(%i[juno1 juno2 juno12 lush])
      expect(bench.select('L.fx.reverb')[0].map(&:family).uniq).to eq([:reverb])
      expect(bench.select('fx.reverb.hall')[0].map(&:name)).to eq([:hall])
      expect(bench.select('reverb.hall')[0]).to eq([entry(:reverb, :hall)])
      expect(bench.select(:dnb_reese)[0].map(&:name)).to eq([:dnb_reese])
      expect(bench.select('preset.dnb_reese')[0].map(&:name)).to eq([:dnb_reese])
      expect(bench.select(:kit)[0].map(&:name)).to include(:tr808, :tr909)
      expect(bench.select(nil, find: 'reese')[0].map(&:name)).to include(:dnb_reese, :jungle_reese)
      # One entry named twice is benched once
      expect(bench.select([:squeeze, 'squeeze.eleven'])[0].map(&:name)).to eq(%i[default eleven])
    end

    it 'skips SQ-80 entries unless named, and kinds without materials' do
      entries, skipped = bench.select(:instrument)
      expect(entries.map(&:family)).not_to include(:sq80)
      expect(entries.map(&:name).grep(/\Asq80_/)).to be_empty
      expect(skipped.map { |e, _| e.name }).to include(:classic, :sq80_glass)
      expect(bench.select('sq80.glass')[0].map(&:name)).to eq([:glass])

      entries, skipped = bench.select(:mastering)
      expect(entries).to be_empty
      expect(skipped.first[1]).to include('a master')
    end

    it 'raises with suggestions for unknown words' do
      expect { bench.select(:revreb) }.to raise_error(MB::Sound::Library::Bench::Error, /no family, kind, or entry name.*reverb/m)
      expect { bench.select('reverb.hal') }.to raise_error(ArgumentError, /no reverb :hal.*hall/m)
    end
  end

  describe 'materials' do
    it 'gives effects the arp, the break, and the pad' do
      expect(bench.materials_for(entry(:reverb, :hall)).map(&:key)).to eq(%i[arp break pad])
    end

    it 'gives instruments the phrases of their role, then their genre template phrase' do
      expect(bench.role_of(entry(:preset, :dnb_reese))).to eq(:bass)
      expect(bench.role_of(entry(:preset, :dnb_pad))).to eq(:pad)
      expect(bench.role_of(entry(:preset, :jungle_flute))).to eq(:lead)
      expect(bench.role_of(entry(:preset, :funk_beat))).to eq(:drums)
      expect(bench.role_of(entry(:struck, :bell))).to eq(:struck)
      expect(bench.role_of(entry(:preset, :tine_piano))).to eq(:keys)

      reese = bench.materials_for(entry(:preset, :dnb_reese))
      expect(reese.map(&:key)).to eq(%i[bass_riff bass_long template])
      t = reese.last
      expect(t.bpm).to eq(MB::Sound.genre(:dnb).tempo)
      expect(t.about).to include('dnb :riff', 'role :bass', 'scene :drop')
      clip = t.build
      expect(clip).not_to be_looping
      expect(clip.length).to eq(MB::Sound.genre(:dnb).clips[:riff].length * (8 / (MB::Sound.genre(:dnb).clips[:riff].length.to_f * 240 / 174)).round)
    end

    it 'gives kits two beats and their template beat, all finite' do
      kit = bench.materials_for(entry(:machine, :tr909))
      expect(kit.map(&:key)).to eq(%i[drums_beat drums_busy template])
      kit.each { |m| expect(m.build.rows.values).to all(satisfy { |c| !c.looping? }) }
    end

    it 'plays the phrases and audio as finite graphs (Entry#audition)' do
      g = MB::Sound::L.fx.reverb.hall.audition(:break)
      expect(g.channel_count).to eq(2)
      expect(MB::Sound::L.fx.reverb.hall.auditions).to eq(%i[arp break pad])
      expect { MB::Sound::L.fx.reverb.hall.audition(:bass_riff) }.to raise_error(ArgumentError, /no :bass_riff material.*arp, break, pad/)
    end

    it 'makes `play L.fx.x` play the effect on the arp' do
      g = MB::Sound::Library::Audition.playable(MB::Sound::L.fx.chorus.juno1)
      expect(g.to_s).to include('on the A7 arp')
    end
  end

  describe '.match' do
    it 'reaches the target, holds the ceiling, trims quiet tails, and fades cut ones' do
      loud = 110.hz.saw.sample(48000)
      quiet = Numo::SFloat.zeros(48000)
      data, info = bench.match([Numo::SFloat.hstack([loud, quiet]), Numo::SFloat.hstack([loud, quiet])], cut: true)
      expect(info[:lufs]).to be_within(0.05).of(-20)
      expect(info[:cut]).to be(false) # the trim found the end
      expect(data[0].length).to eq(48000 + 12000)

      spiky = Numo::SFloat.zeros(96000)
      spiky[1000] = 1.0
      spiky[40000..] = 220.hz.sine.sample(56000) * 0.001
      _, info = bench.match([spiky, spiky.dup])
      expect(info[:peak_bound]).to be(true)
      expect(info[:true_peak]).to be_within(0.05).of(-1)
      expect(info[:lufs]).to be < -20

      _, info = bench.match([Numo::SFloat.zeros(4800)] * 2)
      expect(info[:silent]).to be(true)
    end
  end

  describe '.run, the set directory, and the notes read-back' do
    before(:context) do
      @root = Dir.mktmpdir('bench-', SpecTmp::ROOT)
      @result = MB::Sound::Library::Bench.run(:squeeze, root: @root, materials: [:arp], io: nil)
      @dir = @result.dir
      @set = JSON.parse(File.read(File.join(@dir, 'set.json')))
    end

    it 'renders a tiny family, each file matched to -20 LUFS within 0.5 LU' do
      expect(@result.measures.length).to eq(3) # dry + default + eleven
      files = Dir[File.join(@dir, 'arp', '*.flac')].sort
      expect(files.map { |f| File.basename(f) }).to eq(%w[dry.flac squeeze_default.flac squeeze_eleven.flac])
      files.each do |f|
        l = MB::Sound.loudness(f)
        expect(l.integrated).to be_within(0.5).of(-20), f
        expect(l.true_peak).to be <= -0.9
      end
    end

    it 'writes the fields build_manifest.py and the Bench page read' do
      expect(@set.keys).to include('id', 'title', 'date', 'summary', 'groups', 'bench')
      expect(@set['id']).to eq(File.basename(@dir))
      expect(@set['id']).to match(/\Apresets-squeeze-\d{4}-\d\d-\d\d\z/)
      items = @set['groups'].flat_map { |g| g['items'] }
      expect(@set['groups'].map { |g| g['id'] }).to eq(['arp'])
      expect(items.map { |i| i['id'] }).to eq(["#{@set['id']}.dry.arp", "#{@set['id']}.squeeze.default.arp", "#{@set['id']}.squeeze.eleven.arp"])
      items.each do |i|
        expect(i.keys).to contain_exactly(*described_class::ITEM_KEYS)
        i['variants'].each do |v|
          expect(v.keys).to contain_exactly(*described_class::VARIANT_KEYS)
          expect(v['file']).to start_with("audio/#{@set['id']}/")
          expect(File).to exist(File.join(@root, v['file'].delete_prefix('audio/')))
        end
      end
      eleven = items.last
      expect(eleven['note']).to include('squeeze :eleven', 'extreme', 'LUFS')
      expect(eleven['variants'][0]['code']).to start_with('bpm 120; play L.fx.eleven.audition(:arp).at(')
      meta = @set['bench']['items'][eleven['id']]
      expect(meta['entry']).to include('family' => 'squeeze', 'name' => 'eleven', 'head_path' => 'L.fx.eleven')
      expect(meta['measure']['lufs']).to be_within(0.5).of(-20)
    end

    it 'writes the console lines as Ruby that runs' do
      items = @set['groups'].flat_map { |g| g['items'] }
      items.each do |i|
        code = i['variants'][0]['code']
        expect(Prism.parse(code).errors).to be_empty, code
        # (the line without its play: the graph it would play)
        expr = code.lines.first.sub(/\Abpm [\d.]+; play /, '').strip
        g = MB::Sound.module_eval(expr.gsub('L.fx', 'MB::Sound::L.fx'))
        expect(g).to respond_to(:sample).or respond_to(:channel_count)
      end
    end

    it 'writes bench_set.py, which appends the set without its bench key' do
      py = File.read(File.join(@dir, 'bench_set.py'))
      expect(py).to include('NOT published', 'sets.append', File.join(@dir, 'set.json'), 'squeeze.eleven')
      python = ['python3', 'python'].find { |p| system(p, '--version', out: File::NULL, err: File::NULL) }
      skip 'no python' unless python
      out, status = Open3.capture2e(python, '-I', '-c', "import json\nsets = []\nexec(open(#{File.join(@dir, 'bench_set.py').inspect}).read())\nprint(json.dumps(sets))")
      expect(status).to be_success, out
      sets = JSON.parse(out)
      expect(sets.length).to eq(1)
      expect(sets[0].keys).to contain_exactly('id', 'title', 'date', 'summary', 'groups')
    end

    it 'reads a notes export back per preset' do
      id = @set['id']
      doc = ->(item) { item.gsub(/[^A-Za-z0-9_-]/, '_') }
      export = {
        doc.("#{id}.squeeze.eleven.arp") => { 'item' => "#{id}.squeeze.eleven.arp", 'set' => id, 'verdict' => 'problem', 'text' => 'pumps too hard', 'blind' => false, 'updated' => '2026-10-30T20:00:00Z' },
        doc.("#{id}.squeeze.default.arp") => { 'item' => "#{id}.squeeze.default.arp", 'set' => id, 'verdict' => 'good', 'text' => '', 'blind' => false },
        doc.("#{id}.dry.arp") => { 'item' => "#{id}.dry.arp", 'set' => id, 'verdict' => '', 'text' => 'nice arp' },
        doc.("#{id}.squeeze.gone.arp") => { 'item' => "#{id}.squeeze.gone.arp", 'set' => id, 'verdict' => 'good' },
        'other_set_item' => { 'item' => 'other.item', 'set' => 'other', 'verdict' => 'good' },
      }
      path = File.join(@root, 'notes.json')
      File.write(path, JSON.generate(export))

      notes = bench.read_notes(id, path, root: @root)
      expect(notes.presets.map { |p| [p.head_path, p.status] }).to eq([[entry(:squeeze, :default).head_path, :good], ['L.fx.eleven', :problem]])
      expect(notes.fixes.map(&:head_path)).to eq(['L.fx.eleven'])
      expect(notes.unmatched).to eq([doc.("#{id}.squeeze.gone.arp")])
      text = notes.to_s
      expect(text).to include('2 of 2 presets heard', 'Fix list:', 'L.fx.eleven: arp: problem "pumps too hard"', 'dry arp: "nice arp"', 'Sounds good:')
      expect(notes.to_h['fix']).to eq(['L.fx.eleven'])

      # The other export shapes: an array of documents, and { documents: [{ id:, data: }] }
      list = export.values
      expect(bench.read_notes(@dir, JSON.generate(list)).fixes.map(&:head_path)).to eq(['L.fx.eleven'])
      wrapped = { 'documents' => export.map { |k, v| { 'id' => k, 'data' => v } } }
      expect(bench.read_notes(File.join(@dir, 'set.json'), wrapped).good.length).to eq(1)
    end

    it 'renders job files the way another checkout does (--vs)' do
      job = File.join(@root, 'jobs.json')
      eleven = @result.jobs.last
      File.write(job, JSON.generate(
        lib: File.join(bench.checkout_dir, 'lib'), out: File.join(@root, 'before'), lufs: -20.0, ceiling: -1.0, format: 'flac',
        files: { 'arp' => File.join(@dir, 'materials', 'arp.wav') },
        jobs: [{ item: eleven.item, family: 'squeeze', name: 'eleven', material: 'arp', file: eleven.file }, { item: 'x', family: 'squeeze', name: 'nope', material: 'arp', file: 'x' }]
      ))
      expect { bench.run_job_file(job) }.to output(/L\.fx\.eleven .*LUFS.*\n.*nope arp: not here/).to_stdout
      out = JSON.parse(File.read("#{job}.out.json"))
      expect(out['x']).to eq('missing' => true)
      # Same inputs, same code: the same file as this checkout's render
      a = MB::Sound.read(File.join(@root, 'before', "#{eleven.file}.flac"))
      b = MB::Sound.read(File.join(@dir, "#{eleven.file}.flac"))
      expect((a[0] - b[0]).abs.max).to be < 1e-6
    end
  end

  describe '.worktree_for' do
    it 'takes a directory, or names how to make a worktree' do
      expect(bench.worktree_for(bench.checkout_dir)).to eq(bench.checkout_dir)
      expect { bench.worktree_for('no-such-branch-xyz') }.to raise_error(ArgumentError, /git worktree add .*no-such-branch-xyz/)
    end
  end
end
