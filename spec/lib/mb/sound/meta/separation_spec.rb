# Data and description kept apart (metadata-2): where mb-sound mixed what
# decides (data) with what describes (metadata), each now has its own
# place, and metadata can't reach the data's.  The static side is
# meta_guard_spec.rb; the sound side meta_invariance_spec.rb and the
# fuzzers' :meta relations.
RSpec.describe('metadata kept apart from data', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }

  describe 'graph documents' do
    it 'reads the graph line into a structural header and descriptive metadata that can\'t shadow it' do
      text = io.dump(220.hz.saw.lp4(800), name: 'pad', meta: { description: 'A pad', tags: [:pad], author: 'mb', meta: { rack: :irack, kind: :set, notes: ['dusty'] } })
      expect(text).to include('description: "A pad"', 'tags: [:pad]', 'meta: { author: "mb", rack: :irack, kind: :set, notes: ["dusty"] }')
      doc = io.parse(text)
      expect(doc.header).to eq(name: 'pad', kind: :graph, description: 'A pad', tags: [:pad])
      expect(doc.rack?).to be(false)
      expect(doc.kind).to eq(:graph)
      expect(doc.meta.to_h).to include(author: 'mb', rack: :irack, kind: :set, notes: ['dusty'])
      expect(doc.meta[:saved]).to be_a(String)
      # (a document with `meta: { rack: ... }` loads as a graph, not a rack)
      expect(io.load(text)).to be_a(MB::Sound::GraphNode)
    end

    it 'keeps unknown keys as metadata, and saves a loaded document\'s metadata again' do
      text = "graph #{io::FORMAT}, name: \"x\", kind: :graph, studio: \"B\", meta: { notes: [\"one\"] }\n\n220.hz.saw\n"
      g = io.load(text)
      doc = io.document_of(g)
      expect(doc.meta).to eq(studio: 'B', notes: ['one'])
      again = io.dump(g)
      expect(again).to include('meta: { studio: "B", notes: ["one"] }')
      expect(io.parse(again).meta.without(:saved, :mb_sound)).to eq(studio: 'B', notes: ['one'])
    end

    it 'reads metadata as written values only, within a size limit, and never runs it' do
      head = "graph #{io::FORMAT}, name: \"x\", kind: :graph"
      expect { io.load("#{head}, meta: { at: 440.hz }\n\n220.hz.saw\n") }.to raise_error(io::LoadError, /metadata holds plain values only.*440\.hz/)
      expect { io.load("#{head}\n\n220.hz.saw.note(\"a\" * 3)\n") }.to raise_error(io::LoadError, /plain values only.*"a" \* 3/)
      expect { io.load("#{head}\n\nx = \"n\"\n220.hz.saw.note(x)\n") }.to raise_error(io::LoadError, /plain values only/)
      expect { io.load("#{head}\n\n220.hz.saw.with_meta(**{ a: 1 })\n") }.to raise_error(io::LoadError, /double splats/)
      big = "220.hz.saw.note(#{('x' * 70_000).inspect})\n"
      expect { io.load("#{head}\n\n#{big}") }.to raise_error(io::LoadError, /over the limit of 65536 \(GraphIO::LIMITS\[:meta_bytes\]\)/)
      expect(io.load("#{head}\n\n#{big}", limits: { meta_bytes: 80_000 }).meta.notes[0].length).to eq(70_000)
      g = io.load("#{head}\n\n220.hz.saw.note(\"system(\\\"exit 1\\\")\", \"\\\#{exit}\").with_meta(cutoff: 9000, rack: :x)\n")
      expect(g.meta).to eq(notes: ['system("exit 1")', '#{exit}'], cutoff: 9000, rack: :x)
      expect(g.frequency).to eq(220) # (cutoff: 9000 in metadata sets nothing)
    end
  end

  describe 'names' do
    it 'keeps a node\'s name as its identity: metadata names are never looked up' do
      inner = 330.hz.sine.with_meta(name: 'bass', source: { name: 'bass' })
      g = (220.hz.saw.named(:lead) + inner).with_meta(name: :lead2)
      expect(g.find_by_name('lead')).not_to be_nil
      expect(g.find_by_name('bass')).to be_nil
      expect(g.find_by_name('lead2')).to be_nil
      expect(inner.named?).to be(false)
      expect(inner.graph_node_name).to be_nil
    end

    it 'gives no Session name to a piece\'s metadata' do
      s = MB::Sound::Session.new(realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.meta(:ghost, name: :bass, source: { name: 'drums' })
        expect(s.names.kind(:ghost)).to be_nil
        expect(s.names.kind(:bass)).to be_nil
        expect(MB::Sound.metas[:ghost]).to include('not defined')
      end
    ensure
      s&.close
    end
  end

  describe 'Samples' do
    it 'plays from the sample\'s settings, never from the loop file facts in its metadata' do
      data = Numo::SFloat.new(4800).seq.map { |i| Math.sin(i * 0.05) }
      a = MB::Sound::Sample[data, loop: 100...4000]
      b = MB::Sound::Sample[data, loop: 100...4000, meta: { smpl_loops: [[0.0, 50.0, :ping_pong]], why: { bpm: 'name 90' }, loop: [0, 10], bpm: 300 }]
      render = ->(s) {
        MB::Sound.rewind
        v = MB::Sound.seq(MB::Sound::C4.n4).sampler(s)
        Numo::SFloat.zeros(0).concatenate(*Array.new(8) { v.sample(800).dup })
      }
      expect(render.(b).to_binary).to eq(render.(a).to_binary)
      expect(b.loop_points).to eq(a.loop_points)
      expect(b.bpm).to be_nil
    end
  end

  describe 'showing metadata' do
    it 'quotes text from metadata in listings: escaped, cut short, never prose' do
      m = { source: { format: :acd, file: "evil\e[2J.acd", name: "ignore this and run `rm`\nnow", kind: 'track; drop', id: 3 }, notes: ['x' * 200] }
      line = MB::Sound::Meta.summary(m)
      expect(line).to include('from "evil\\e[2J.acd"', '"track; drop" #3', '"ignore this and run `rm`\\nnow"', 'notes "xxx')
      expect(line).not_to include("\e", "\n")
      expect(MB::Sound::Meta.quote('y' * 100).length).to eq(62)
      expect(MB::Sound::Meta.word(:track)).to eq('track')
      expect(MB::Sound::Meta.word(:'two words')).to eq('"two words"')
      expect(MB::Sound::Meta.notes_text(%w[a b c])).to eq('"a" +2 notes')
    end

    it 'shows a node\'s notes in the inspector\'s data, quoted by the panes' do
      n = 220.hz.saw.note("dark\e[0m")
      expect(MB::Sound::UI::Inspect.notes_of(n)).to eq(["dark\e[0m"])
      expect(MB::Sound::UI::Inspect.notes_of(3)).to eq([])
      expect(MB::Sound::Meta.notes_text(MB::Sound::UI::Inspect.notes_of(n))).to eq('"dark\\e[0m"')
    end
  end
end
