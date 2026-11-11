# Metadata (source-meta-1; lib/mb/sound/meta.rb): the value rule, merging,
# summaries, the `meta` statement printer, the text reader, the Session
# store, and metadata carried on graph nodes (Meta::Carrier): printed by
# to_ruby, kept by graph documents, and no part of the sound.
require_relative '../../../support/plan_helpers'

RSpec.describe(MB::Sound::Meta, :aggregate_failures) do
  let(:meta) { MB::Sound::Meta }
  let(:source) { { format: :acd, kind: :track, at: 0x12340, bytes: 5678, name: "the track's own name", fields: { color: 3, height: 80 } } }

  describe '.check' do
    it 'takes plain Ruby: numbers, Strings, Symbols, true, false, nil, Arrays, and Hashes of those' do
      v = { a: [1, 2.5, 3/4r, 'text', :sym, true, false, nil], 'k' => { 3 => { deep: [[], {}] } }, big: 2**80, nan: Float::NAN }
      expect(meta.check(v)).to equal(v)
    end

    it 'names the key path of the first value that is not plain' do
      expect { meta.check({ source: { fields: [1, { x: Object.new }] } }) }
        .to raise_error(ArgumentError, /\Ameta\[:source\]\[:fields\]\[1\]\[:x\] is an Object .*metadata values are plain Ruby/)
      expect { meta.check({ a: -> { 1 } }) }.to raise_error(ArgumentError, /meta\[:a\] is a Proc/)
      expect { meta.check({ a: 1..2 }) }.to raise_error(ArgumentError, /meta\[:a\] is a Range/)
      expect { meta.check({ a: -6.db }) }.to raise_error(ArgumentError, /meta\[:a\] is a MB::Sound::Decibels/)
      expect { meta.check({ a: 440.hz }) }.to raise_error(ArgumentError, /meta\[:a\] is a/)
      expect { meta.check({ a: { 1.5 => 2 } }) }.to raise_error(ArgumentError, /meta\[:a\] has the key 1.5 \(Float\); metadata keys are Symbols, Strings, or Integers/)
    end

    it 'stops at a list that holds itself' do
      a = [1]
      a << a
      expect { meta.check({ loop: a }) }.to raise_error(ArgumentError, /nests deeper than 32 levels/)
    end
  end

  describe '.merge' do
    it 'merges top-level keys into a frozen Hash, replacing a key given again whole' do
      a = meta.merge(nil, source: source)
      b = meta.merge(a, notes: 'x')
      c = meta.merge(b, source: { format: :mod })
      expect(a).to eq(source: source)
      expect(b).to eq(source: source, notes: 'x')
      expect(c).to eq(source: { format: :mod }, notes: 'x')
      expect([a, b, c]).to all(be_frozen)
      expect(meta.merge(b, {})).to equal(b)
      expect(meta.merge(nil, {})).to equal(meta::EMPTY_HASH)
    end

    it 'keeps deeply frozen copies, so the caller\'s values stay theirs' do
      name = +'kick'
      fields = { list: [1, 2], name: name }
      m = meta.merge(nil, source: { fields: fields })
      name << ' drum'
      fields[:list] << 3
      fields[:more] = true
      expect(m).to eq(source: { fields: { list: [1, 2], name: 'kick' } })
      expect(m[:source]).to be_frozen
      expect(m[:source][:fields][:list]).to be_frozen
      expect(m[:source][:fields][:name]).to be_frozen
      expect(fields).not_to be_frozen
    end

    it 'takes Symbol keys at the top and plain values' do
      expect { meta.merge(nil, 'source' => {}) }.to raise_error(ArgumentError, /top-level metadata keys are Symbols/)
      expect { meta.merge(nil, [1]) }.to raise_error(ArgumentError, /metadata is a Hash of plain values \(got an Array/)
      expect { meta.merge(nil, source: { at: Object }) }.to raise_error(ArgumentError, /meta\[:source\]\[:at\] is a Class/)
    end
  end

  describe '.summary' do
    it 'says where a piece came from in one line' do
      expect(meta.summary({ source: source.merge(file: 'project.acd') })).to eq(%(from project.acd, track "the track's own name" at 0x12340, 5.5 KB, 2 fields carried))
      expect(meta.summary({ source: source }, kind: :bus, file: 'D:\\Songs\\old\\project.acd')).to start_with('from project.acd, track ')
      expect(meta.summary({ source: { format: :acd, file: '/a/b/project.acd', bytes: 1_234_567, version: '7.0', unread: 0.19 } }, kind: :set))
        .to eq('from project.acd (acd 7.0), set, 1.2 MB, 19% unread')
      expect(meta.summary({ source: { format: :mod, kind: :sample, id: 4, records: 31, unread: 12, tracker: 'x' } })).to eq('from mod, sample #4, 31 records, 12 bytes unread, + tracker')
      expect(meta.summary({ source: { format: :wav, a: 1, b: 2, c: 3, d: 4 }, notes: 'x' })).to eq('from wav, + 4 more, also notes')
      expect(meta.summary({ source: { unread: 0.005 } }, kind: :track)).to eq('track, 0.5% unread')
    end

    it 'lists the keys of metadata without a source, and says when there is none' do
      expect(meta.summary({ notes: 'x', tags: [:a] }, kind: :knob)).to eq('knob, notes, tags')
      expect(meta.summary({ source: 'a tape' })).to eq('source "a tape"')
      expect(meta.summary({})).to eq('(none)')
      expect(meta.summary(nil)).to eq('(none)')
    end

    it 'writes byte counts in words' do
      expect([0, 1, 1023, 1024, 5678, 150_000, 1_234_567, 5 * 1024**3].map { |n| meta.bytes_text(n) })
        .to eq(['0 bytes', '1 byte', '1023 bytes', '1.0 KB', '5.5 KB', '146 KB', '1.2 MB', '5.0 GB'])
    end
  end

  describe '.statement and .parse' do
    let(:big) do
      {
        source: {
          format: :acd, kind: :bus, id: 2,
          fields: { 'plug-in' => ['Reverb', 'Big Hall', 4096], 7 => 1/3r, list: (1..40).to_a, flag: nil, deep: { a: { b: [true, false, -1.5, :"two words"] } } },
        },
        notes: "two\nlines",
      }
    end

    it 'prints one line when it fits, for a piece and for the set' do
      expect(meta.statement(:a3, { source: { format: :acd, at: 16 } })).to eq(['meta :a3, source: { format: :acd, at: 16 }'])
      expect(meta.statement(nil, { notes: 'x' })).to eq(['meta notes: "x"'])
      expect(meta.statement(:"bass/cutoff", { n: 1 })).to eq(['meta :"bass/cutoff", n: 1'])
    end

    it 'opens long metadata over lines no wider than asked, still one Ruby statement' do
      lines = meta.statement(:fx1, big, width: 80)
      expect(lines.first).to eq('meta(:fx1,')
      expect(lines.last).to end_with(')')
      expect(lines.map(&:length).max).to be <= 80
      expect(lines.length).to be > 6
      result = Prism.parse(lines.join("\n"))
      expect(result.errors).to eq([])
      call = result.value.statements.body
      expect(call.length).to eq(1)
      args = call[0].arguments.arguments
      expect(args[0].unescaped).to eq('fx1')
      expect(meta.literal(args[1])).to eq(big)

      set = meta.statement(nil, big, width: 60)
      expect(set.first).to eq('meta(')
      expect(meta.literal(Prism.parse(set.join("\n")).value.statements.body[0].arguments.arguments[0])).to eq(big)
    end

    it 'reads back the text of any plain value, same values and classes' do
      [big, 3/4r, -3/4r, 3r, -2, 1.0e-7, Float::INFINITY, -Float::INFINITY, nil, true, :sym, 'é "q" \\', [], {}, { 'a b' => [1, [2, { c: nil }]] }].each do |v|
        back = meta.parse(MB::Sound::RubyValue.to_ruby(v))
        expect(back).to eql(v)
      end
      expect(meta.parse('Float::NAN')).to be_nan
    end

    it 'runs nothing: text that is not a plain value raises' do
      ['system("x")', '`ls`', 'Object.new', '"a#{1}"', 'File', '1 + 2', '{ **x }', '1; 2', '{ a: }', '440.hz', ':a.to_proc', '[1, exit]'].each do |text|
        expect { meta.parse(text) }.to raise_error(ArgumentError, /metadata text/), text
      end
    end
  end

  describe MB::Sound::Meta::Store do
    let(:store) { described_class.new }

    it 'keeps the set\'s own metadata and each name\'s, in the order names first got some' do
      expect(store).to be_empty
      expect(store[:a3]).to equal(meta::EMPTY)
      expect(store[nil]).to equal(meta::EMPTY)
      expect(store.merge(:b, n: 1)).to eq(n: 1)
      store.merge(:a, n: 2)
      store.merge(:b, m: 3)
      store.merge(nil, source: { file: 'x.mod' })
      expect(store.names).to eq(%i[b a])
      expect(store.to_h).to eq(b: { n: 1, m: 3 }, a: { n: 2 })
      expect(store[]).to eq(source: { file: 'x.mod' })
      expect(store.size).to eq(2)
      expect(store).not_to be_empty
    end

    it 'forgets a name\'s or the set\'s' do
      store.merge(:a, n: 2)
      store.merge(nil, n: 1)
      expect(store.clear(:a)).to eq(n: 2)
      expect(store.clear(:a)).to eq({})
      expect(store.names).to eq([])
      expect(store.clear).to eq(n: 1)
      expect(store).to be_empty
    end

    it 'takes names as Symbols' do
      expect { store['a3'] }.to raise_error(ArgumentError, /meta takes a piece's name as a Symbol/)
      expect { store.merge(3, n: 1) }.to raise_error(ArgumentError, /as a Symbol/)
    end
  end

  describe MB::Sound::Meta::Carrier do
    let(:xm) { { format: :xm, kind: :instrument, id: 3, at: 0x1f40, bytes: 263, fields: { 'vol' => 1/2r, list: [1, 2.5, nil, true] } } }

    def graph
      MB::Sound.with_seed(4) { 110.hz.saw.lp4(700, resonance: 0.4).softclip(0.3, 0.9) + MB::Sound.noise.at(-30.db) }
    end

    it 'gives every node and bundle #with_meta (chaining, merging) and #meta (a frozen Hash)' do
      n = 220.hz.saw.lp4(800)
      expect(n.meta).to equal(meta::EMPTY)
      expect(n.with_meta(source: xm)).to equal(n)
      expect(n.with_meta({ notes: 'x' }, tags: [:a]).meta).to eq(source: xm, notes: 'x', tags: [:a])
      expect(n.meta).to be_frozen
      expect(n.with_meta(nil).meta).to eq({})

      b = [220.hz.saw, 221.hz.saw].channels.with_meta(source: xm)
      expect(b.meta).to eq(source: xm)
      expect(b[0].meta).to eq({})
      expect(n.lp4(300).meta).to eq({}) # (a new node is a new object)

      expect { n.with_meta(source: { node: n }) }.to raise_error(ArgumentError, /meta\[:source\]\[:node\] is a/)
      expect { n.with_meta(:source) }.to raise_error(ArgumentError, /metadata is a Hash of plain values/)
      expect(n.meta).to eq({})
    end

    it 'prints with the node (to_ruby) and survives a graph document' do
      n = 220.hz.saw.lp4(800).with_meta(source: xm)
      expect(n.to_ruby).to eq('220.hz.saw.lp4(800).with_meta(source: { format: :xm, kind: :instrument, id: 3, at: 8000, bytes: 263, fields: { "vol" => 1/2r, list: [1, 2.5, nil, true] } })')
      text = MB::Sound::GraphIO.dump(n, name: 'carried')
      loaded = MB::Sound::GraphIO.load(text)
      expect(loaded.meta).to eq(n.meta)
      expect(loaded.meta[:source][:fields]['vol']).to eql(1/2r)
      expect(MB::Sound::GraphIO.dump(loaded, name: 'carried').lines.last).to eq(text.lines.last)

      b = [220.hz.saw, 221.hz.saw].channels.with_meta(notes: 'wide')
      expect(b.to_ruby).to eq('[220.hz.saw, 221.hz.saw].channels.with_meta(notes: "wide")')
    end

    it 'is no part of the sound: the same samples with and without it, plans off and on' do
      plain = graph
      carried = graph.with_meta(source: xm, notes: 'x')
      a = SpecBuffers.join(Array.new(12) { plain.sample(800).dup })
      b = SpecBuffers.join(Array.new(12) { carried.sample(800).dup })
      expect(a.abs.max).to be > 0.1
      expect(b.to_binary == a.to_binary).to be(true)

      # (metadata given to nodes inside the graph: the same samples, and
      # the plan layer's fused code gives them bit for bit too)
      inner = -> { 110.hz.saw.with_meta(source: xm).lp4(700, resonance: 0.4).with_meta(notes: 'f').softclip(0.3, 0.9).with_meta(source: xm) + MB::Sound.noise.at(-30.db) }
      g = MB::Sound.with_seed(4) { inner.call }
      expect(SpecBuffers.join(Array.new(12) { g.sample(800).dup }).to_binary == a.to_binary).to be(true)
      plan_compare(fallbacks: true) { |_c| inner.call }
    end

    it 'adds no instance variable to a node (one layout per class)' do
      n = 220.hz.saw.lp4(800)
      before = n.instance_variables
      n.with_meta(source: xm)
      expect(n.instance_variables).to eq(before)
      expect(before).to include(:@carried_meta)
      b = [220.hz.saw, 221.hz.saw].channels
      before = b.instance_variables
      b.with_meta(source: xm)
      expect(b.instance_variables).to eq(before)
    end
  end
end
