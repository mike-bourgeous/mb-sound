# Round 2's layers (metadata-2; the maintainer, 2026-11-11: "Can there be a
# layered process where a raw file reader only produces metadata, and then
# the layer above that converts some to data, etc.?"): readers make Facts,
# interpreters consume chosen facts into typed data with Provenance, and
# the facts nobody consumed become description.
require_relative '../../../../support/midi_writer'
require_relative '../../../../support/sf2_writer'

RSpec.describe('metadata layers: facts, interpreters, provenance', :aggregate_failures) do
  let(:tone) { Numo::SFloat.new(48000).seq.map { |i| Math.sin(i * 0.05) * 0.5 } }
  let(:riff) { MB::Sound::Sample::Riff }

  describe MB::Sound::Facts do
    it 'holds what a WAV file says, each fact with its chunk and offset' do
      path = tmp_path('f.wav')
      riff.write(path, tone, acid: { one_shot: true, root: 60, beats: 0, tempo: 0.0 }, smpl: { unity_note: 48, loops: [[10, 400]] },
                             info: { 'INAM' => 'Hit', 'ISFT' => 'Tool' }, extra: [['bext', 'x' * 6]])
      facts = MB::Sound::Facts.of_riff(riff.read(path))
      expect(facts['acid.flags'].value & 1).to eq(1)
      expect(facts['acid.flags'].record).to eq('acid')
      expect(facts['acid.flags'].at).to eq(riff.read(path).chunks.find { |id, _, _| id == 'acid' }[1])
      expect(facts['smpl.loop[0]'].value).to eq([10, 400, :forward])
      expect(facts['INFO.ISFT'].value).to eq('Tool')
      expect(facts['chunk.bext'].value).to eq([riff.read(path).chunks.find { |id, _, _| id == 'bext' }[1], 6])
      expect(facts).to be_frozen
      expect(facts.select_keys('acid.*').keys).to all(start_with('acid.'))
    end

    it 'refuses an interpreter that reports a fact it does not declare' do
      facts = MB::Sound::Facts.of_tags({ 'title' => 'x', 'bpm' => '120' })
      sneaky = Object.new
      sneaky.extend(MB::Sound::Facts::Interpreter)
      def sneaky.name = 'sneaky'
      def sneaky.consumes = %w[tag.title]
      def sneaky.interpret(_facts) = MB::Sound::Facts::Interpretation.new(interpreter: name, consumed: %w[tag.title tag.bpm])
      expect { MB::Sound::Facts.interpret(facts, sneaky) }.to raise_error(ArgumentError, /sneaky consumed tag.bpm, which it doesn't declare/)
      r = MB::Sound::Facts.interpret(facts, MB::Sound::Facts::Consumer.new('t', %w[tag.title]))
      expect(r.unconsumed.to_fields).to eq('tag.bpm' => '120')
    end
  end

  describe 'Samples (the worked example: a loop file\'s one-shot flag)' do
    it 'turns the flag into the one_shot setting with its provenance, and leaves unused facts as description' do
      path = tmp_path('hit.wav')
      riff.write(path, tone, acid: { one_shot: true, root: 60, beats: 4, tempo: 120.0 }, info: { 'INAM' => 'Hit', 'ISFT' => 'Tool' })
      s = MB::Sound::Sample[path]
      expect(s.one_shot?).to be(true)
      p = s.provenance(:one_shot)
      expect([p.via, p.fact, p.record, p.interpreter]).to eq([:acid, 'acid.flags', 'acid', 'Sample::LoopInfo'])
      expect(p.at).to eq(riff.read(path).chunks.find { |id, _, _| id == 'acid' }[1])
      expect(s.why(:one_shot)).to be_a(String)
      expect(s.meta_source[:one_shot]).to eq(:acid)
      fields = s.meta[:source][:fields]
      expect(fields).to include('acid.tempo' => 120.0, 'INFO.ISFT' => 'Tool') # (a one-shot's tempo isn't used)
      expect(fields).not_to have_key('acid.flags')
      expect(fields).not_to have_key('INFO.INAM') # (described: title)
      expect(s.meta[:title]).to eq('Hit')
      expect(s.name).to eq('hit.wav')
      expect(p.to_s).to start_with('one_shot: acid "acid.flags" (wav acid chunk at 0x')
      expect(s.reverse.provenance(:one_shot)).to eq(p) # (views and edits keep it)
    end

    it 'says where saved settings and detected ones came from' do
      path = tmp_path('saved.flac')
      MB::Sound::Sample[tone, bpm: 90.0, name: 'saved'].save(path)
      s = MB::Sound::Sample[path]
      expect([s.provenance(:bpm).via, s.provenance(:bpm).fact]).to eq([:saved, 'tag.mb_sample_bpm'])
      d = MB::Sound::Sample[tone].detect_tempo
      expect(d.provenance(:bpm).via).to eq(:detected)
      expect(d.why(:bpm)).to match(/\Adetected [\d.]+ BPM/)
    end
  end

  describe 'MIDI clips' do
    it 'gives a clip its notes\' provenance and keeps unread meta events as description' do
      path = tmp_path('m.mid')
      MidiWriter.write(path, tracks: [{ name: 'Lead', notes: [[0, 480, 60, 100], [480, 960, 64, 100]],
                                        meta: [[0x07, 'drop here'], [0x05, 'la'], [0x01, 'played live']] }])
      clip = MB::Sound.midi_clip(path)
      expect(clip.provenance(:events).why).to start_with('2 notes of track 1 "Lead"')
      expect(clip.provenance(:events).interpreter).to eq('MIDI::Import')
      expect(clip.meta.notes).to eq(['played live'])
      expect(clip.meta[:source][:fields]).to include('track[1].cue[0]' => 'drop here', 'track[1].lyric[0]' => 'la')
      expect(clip.transpose(2).provenance).to eq({}) # (a new clip is a new object)
    end
  end

  describe 'SoundFonts' do
    it 'reads the name from INAM as data, describes the rest, and keeps unread INFO texts as fields' do
      path = tmp_path('font.sf2')
      SF2Writer.write(path, info: { 'INAM' => 'Spec Font', 'ICMT' => 'free', 'ISFT' => 'Polyphone', 'ICRD' => '2001' },
                            samples: [{ name: 'sine', data: Array.new(1000) { |i| Math.sin(i * 0.1) * 0.5 }, rate: 44100, pitch: 60 }],
                            instruments: [{ name: 'Sine', zones: [{ sample_id: 0 }] }], presets: [{ name: 'Sine', program: 0, zones: [{ instrument: 0 }] }])
      font = MB::Sound::Sampler::SF2.open(path)
      expect(font.name).to eq('Spec Font')
      expect(font.provenance(:name).fact).to eq('INFO.INAM')
      expect(font.meta.notes).to eq(['free'])
      expect(font.meta[:source][:fields]).to eq('INFO.ISFT' => 'Polyphone', 'INFO.ICRD' => '2001')
    end
  end

  describe 'graph documents' do
    it 'reads the graph line as facts: structural keys as header data with provenance, the rest as description' do
      text = MB::Sound::GraphIO.dump(220.hz.saw, name: 'facts', meta: { tags: [:x], studio: 'B' })
      doc = MB::Sound::GraphIO.parse(text)
      expect(doc.facts['graph.name'].value).to eq('facts')
      expect(doc.facts['graph.name'].at).to eq(text.index('name: "facts"'))
      expect(doc.provenance(:name).interpreter).to eq('GraphIO::Loader')
      expect(doc.provenance(:tags).interpreter).to eq('Library::Index')
      expect(doc.header).to include(name: 'facts', tags: [:x])
      expect(doc.meta[:studio]).to eq('B')
      expect(doc.provenance(:studio)).to be_nil
    end
  end

  describe 'sidecars' do
    it 'are facts the text interpreter describes' do
      path = tmp_path('a.aiff')
      File.write(path, '')
      MB::Sound::Meta::Formats.write_sidecar(path, { notes: ['n'], author: 'mb' })
      expect(MB::Sound::Meta::Formats.read_sidecar(path)).to eq(notes: ['n'], author: 'mb')
    end
  end
end
