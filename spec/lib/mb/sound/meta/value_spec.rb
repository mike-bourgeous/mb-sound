require 'prism'

RSpec.describe(MB::Sound::Meta::Value, :aggregate_failures) do
  let(:source) { { format: :acd, kind: :track, id: 3, at: 0x1f40, fields: { 'vol' => 1/2r, list: [1, 2.5, nil, true] } } }

  describe '.[] and .of' do
    it 'checks and freezes a Hash, and gives EMPTY for nothing' do
      v = described_class[notes: 'x', source: source]
      expect(v).to be_frozen
      expect(v.to_h).to be_frozen
      expect(v[:source][:fields]).to be_frozen
      expect(described_class.of(nil)).to equal(described_class::EMPTY)
      expect(described_class.of({})).to equal(described_class::EMPTY)
      expect(described_class.of(v)).to equal(v)
      expect(described_class[{ a: 1 }, b: 2]).to eq(a: 1, b: 2)
      expect(MB::Sound::Meta::EMPTY).to equal(described_class::EMPTY)
    end

    it 'takes plain values only, naming the key path, and Symbols at the top' do
      expect { described_class[source: { node: 220.hz }] }.to raise_error(ArgumentError, /meta\[:source\]\[:node\] is a/)
      expect { described_class.of('notes') }.to raise_error(ArgumentError, /metadata is a Hash/)
      expect { described_class.of('k' => 1) }.to raise_error(ArgumentError, /top-level metadata keys are Symbols/)
    end

    it 'keeps the vocabulary\'s shapes, and any other key as given' do
      expect { described_class[notes: 3] }.to raise_error(ArgumentError, /meta\[:notes\] is commentary/)
      expect { described_class[notes: ['a', :b]] }.to raise_error(ArgumentError, /meta\[:notes\]/)
      expect { described_class[tags: [1]] }.to raise_error(ArgumentError, /meta\[:tags\]/)
      expect { described_class[source: 'a file'] }.to raise_error(ArgumentError, /meta\[:source\] is where it came from/)
      expect { described_class[author: ['a']] }.to raise_error(ArgumentError, /meta\[:author\]/)
      v = described_class[cutoff: 9000, rack: :x, mode: :spectral, 'odd': { 1 => [nil] }]
      expect(v[:rack]).to eq(:x)
      expect(v.keys).to eq(%i[cutoff rack mode odd])
    end
  end

  describe 'readers' do
    it 'reads the vocabulary, lists as Arrays' do
      v = described_class[notes: 'one', tags: :dark, links: %w[a b], author: 'mb', license: 'CC0-1.0', source: source, pack: :ambient]
      expect(v.notes).to eq(['one'])
      expect(v.tags).to eq([:dark])
      expect(v.links).to eq(%w[a b])
      expect([v.author, v.license, v.pack]).to eq(['mb', 'CC0-1.0', :ambient])
      expect(v.source).to eq(source)
      e = described_class::EMPTY
      expect([e.notes, e.tags, e.links, e.author, e.source]).to eq([[], [], [], nil, nil])
      expect(e.notes).to be_frozen
    end

    it 'reads like the Hash it holds' do
      v = described_class[notes: ['a'], source: source]
      expect(v[:source][:id]).to eq(3)
      expect(v.dig(:source, :fields, 'vol')).to eql(1/2r)
      expect(v.fetch(:notes)).to eq(['a'])
      expect(v.key?(:notes)).to be(true)
      expect(v.keys).to eq(%i[notes source])
      expect(v.size).to eq(2)
      expect(v.map { |k, _| k }).to eq(%i[notes source])
      expect(v).to eq(notes: ['a'], source: source)
      expect({ notes: ['a'], source: source }).to eq(v)
      expect(v).to eq(described_class[notes: ['a'], source: source])
      expect(v.eql?(described_class[notes: ['a'], source: source])).to be(true)
      expect({ v => 1 }[described_class[notes: ['a'], source: source]]).to eq(1)
      expect({ **v }).to eq(v.to_h)
      case v
      in { source: { format: :acd, id: } }
        expect(id).to eq(3)
      end
    end
  end

  describe 'new values' do
    it 'merges by top-level key (a key given again replaced whole), adds notes, and leaves keys out' do
      v = described_class[source: source, notes: 'x']
      w = v.with(source: { format: :mod })
      expect(w).to eq(source: { format: :mod }, notes: 'x')
      expect(v).to eq(source: source, notes: 'x')
      expect(v.merge({})).to equal(v)
      expect(v.note('y', 'z').notes).to eq(%w[x y z])
      expect { v.note(3) }.to raise_error(ArgumentError, /a note is a String/)
      expect(v.without(:notes)).to eq(source: source)
      expect(v.slice(:notes)).to eq(notes: 'x')
      expect(v.without(:notes, :source)).to equal(described_class::EMPTY)
      # (frozen values merged in stay the same objects)
      expect(w.merge(notes: 'q')[:source]).to equal(w[:source])
    end
  end

  describe 'printing and parsing' do
    it 'prints as a Ruby Hash literal that parses back to the same value, never run' do
      v = described_class[notes: ["it's \"quoted\"", '#{not run}'], source: source, big: 1e300, neg: -3/4r]
      text = v.to_ruby
      expect(Prism.parse(text).errors).to be_empty
      back = described_class.parse(text)
      expect(back).to eq(v)
      expect(back.dig(:source, :fields, 'vol')).to eql(1/2r)
      expect(described_class::EMPTY.to_ruby).to eq('{}')
      expect(described_class.parse('{}')).to equal(described_class::EMPTY)
      expect { described_class.parse('[1]') }.to raise_error(ArgumentError, /holds a Hash/)
      expect { described_class.parse('{ a: system("x") }') }.to raise_error(ArgumentError, /plain values only/)
      expect(v.inspect).to start_with('#<MB::Sound::Meta::Value notes: [')
    end
  end

  describe MB::Sound::Meta::Carrier do
    it 'gives nodes, bundles, clips, and kits #note and #with_meta in place, printed by to_ruby' do
      n = 220.hz.saw.note('raw').lp4(800).note('darker', 'warm')
      expect(n.meta.notes).to eq(%w[darker warm])
      expect(n.to_ruby).to eq('220.hz.saw.note("raw").lp4(800).note("darker", "warm")')
      expect(n.note).to equal(n)

      clip = MB::Sound.seq(MB::Sound::A1, MB::Sound::A2).n8.loop.named(:bass).note('from the old demo')
      expect(clip.meta.notes).to eq(['from the old demo'])
      expect(clip.name).to eq(:bass)
      expect(clip.to_ruby).to eq('seq(A1, A2).n8.loop.named(:bass).note("from the old demo")')
      expect(clip.transpose(12).meta).to equal(MB::Sound::Meta::EMPTY) # (a new clip is a new object, as with names)

      kit = MB::Sound.grid(4, kick: 'x...').with_meta(author: 'mb')
      expect(kit.meta.author).to eq('mb')
    end

    it 'gives Samples and library entries copies' do
      s = MB::Sound::Sample[Numo::SFloat.zeros(64), name: 'z']
      t = s.note('silence')
      expect(s.meta).to equal(MB::Sound::Meta::EMPTY)
      expect(t.meta.notes).to eq(['silence'])
      expect(t.lineage[1]).to eq(:note)

      e = MB::Sound::Library::Entry.new(name: :x, kind: :effect, family: :preset)
      f = e.note('a test').with_meta(pack: :demo)
      expect(e.meta).to equal(MB::Sound::Meta::EMPTY)
      expect(f.meta).to eq(notes: ['a test'], pack: :demo)
      expect(f.name).to eq(:x)
      expect(f.with_meta(nil).meta).to equal(MB::Sound::Meta::EMPTY)
    end

    it 'gives takes metadata saved as the replay\'s meta:' do
      s = MB::Sound::Session.new(realtime: false)
      begin
        take = MB::Sound::Take.new(session: s)
        expect(take.note('second verse idea')).to equal(take)
        text = take.to_ruby
        expect(text).to include('  meta: { notes: ["second verse idea"] },')
        expect(Prism.parse(text).errors).to be_empty
        expect(take.replay.meta).to eq(notes: ['second verse idea'])
      ensure
        s.close
      end
    end

    it 'keeps Session pieces\' notes in the Store' do
      store = MB::Sound::Meta::Store.new
      store.note(:bass, 'doubled')
      store.note(:bass, 'an octave down')
      expect(store[:bass].notes).to eq(['doubled', 'an octave down'])
      expect(store.note(nil, 'set').notes).to eq(['set'])
    end
  end
end
