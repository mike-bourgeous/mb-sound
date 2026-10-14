# Graph-io phase 3: clips in graph documents (recipes of seq, grid, kits,
# note marks, transforms; events(...) for clips without a recipe).
require_relative '../../../support/graph_sweep'

# Graphs for the spec below, written in MB::Sound so note names resolve as
# in the console.
module MB::Sound
  module GraphIOClipSpec
    # Note names (C4) come from MB::Sound.const_missing
    def self.const_missing(name)
      MB::Sound.const_get(name)
    end

    # Each builds a graph (in MB::Sound, as the console would) that plays a
    # clip, with the text the clip part prints as
    GRAPHS = {
      'seq with lengths' => [-> { seq(C4, E4, G4.n4).n8.loop.tone.saw }, 'seq(C4, E4, G4.n4).n8.loop'],
      'note marks' => [
        -> { seq(!A1, ~C2, Rest, C3.n4, Tie, G2.chance(0.5), ~!E2.every(2, from: 2), A1.fill(:big), (!A1).n8, A1.slide(1.1).acc).n16.loop.tone },
        'seq(!A1, ~C2, Rest, C3.n4, Tie, G2.chance(0.5), ~!E2.every(2, from: 2), A1.fill(:big), (!A1).n8, (!A1).slide(11r/10)).n16.loop',
      ],
      'acid' => [-> { acid(A1, !C2, ~A2, R, A1.up).loop.tone.ramp }, 'acid(A1, !C2, ~A2, Rest, A1.up).loop'],
      'operators' => [-> { c = seq(C4, E4, G4).n16; ((c | c.transpose(7)) & seq(C3).n2).reverse.loop.tone }, '((clip | clip.transpose(7)) & seq(C3).n2).reverse.loop'],
      'feel' => [-> { seq(C4, E4, G4, C5).n16.swing.quantize(8, amount: 0.5).humanize(0.01, vary: true).shuffle.loop.tone }, '.humanize(0.01, vary: true)'],
      'generators' => [-> { (euclid(3, 8, C2) | melody(scale(:minor, :a), 8, seed: 3)).loop.tone }, 'euclid(3, 8, C2) | melody(scale(:minor, A4), 8, seed: 3)'],
      'kit rows' => [
        -> { k = grid(16, kick: 'x...x...', hat: 'x.x.x.x.').loop.named(:beat); 50.hz.sine * k[:kick].env(0, 0.2, 0, 0.05) + 3000.hz.ramp * k[:hat].env(0, 0.03, 0, 0.02) },
        'beat = grid(16, kick: "x...x...", hat: "x.x.x.x.").loop.named(:beat)',
      ],
      'kit fills into tr808' => [
        -> { tr808(grid(16, kick: 'x...x...', clap: '....x...').fill { grid(16, clap: '......xx') }.nofill(:kick).loop, accent: 6.db) },
        "fill {\n  grid(16, clap: \"......xx\")\n}.nofill(:kick).loop",
      ],
      'kit rows taken with kit.rows' => [
        -> { kit = grid(16, kick: 'x...x...', hat: 'x.x.x.x.'); tr808(Sequence::Kit.new(kit.rows.to_h { |n, c| [n, n == :hat ? c.swing(0.56) : c.every(2)] }).loop) },
        %{kit = grid(16, kick: "x...x...", hat: "x.x.x.x.")\ntr808(Sequence::Kit.new({ kick: kit[:kick].every(2), hat: kit[:hat].swing(0.56) }).loop},
      ],
      'Clip.new events' => [
        -> { Sequence::Clip.new([MB::Sound::Sequence::Event.new(start: 0r, length: 1/8r, value: 60, velocity: 0.787), MB::Sound::Sequence::Event.new(start: 1/4r, length: 1/8r, value: 64, velocity: 1.0, accented: true, probability: 0.5)], length: 1/2r).loop.tone },
        "events(\n  [0r, 1r/8, 60, 0.787],\n  [1r/4, 1r/8, 64, 1.0, { probability: 0.5, accented: true }],\n  length: 1r/2\n).loop",
      ],
      'baked transforms (saved as events)' => [-> { seq(C4, E4).n8.loop.bake(echo(1.n16, 2, velocity: 0.5).strum(20.ms)).tone }, "events(\n  [0r, 1r/16, 60, 0.75],"],
      'MIDI transform chains' => [-> { seq(C4, E4).n8.loop.notes.echo(1.n16, 2).tone }, 'seq(C4, E4).n8.loop.notes.echo(1.n16, 2)'],
      'clip synth' => [-> { seq(C4, E4, G4).n8.loop.synth(voices: 2) { |v| v.tone.saw * v.env(0, 0.1, 0.5, 0.1) } }, 'seq(C4, E4, G4).n8.loop.synth(voices: 2)'],
    }.freeze
  end
end

RSpec.describe('graph documents with clips', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }

  def render(graph, buffers: 40, size: 512)
    RecipeHelpers.render(graph, buffers: buffers, size: size)
  end

  def ev(start, length, value, velocity = 0.75, **marks)
    MB::Sound::Sequence::Event.new(start: start, length: length, value: value, velocity: velocity, **marks)
  end

  graphs = MB::Sound::GraphIOClipSpec::GRAPHS

  graphs.each do |name, (factory, text)|
    it "saves, loads, and renders #{name} bit for bit" do
      MB::Sound.seed(1)
      graph = MB::Sound.instance_exec(&factory)
      doc = io.dump(graph, name: 'clips')
      expect(doc).to include(text)

      MB::Sound.seed(99)
      loaded = io.load(doc)
      expect(RecipeHelpers.max_diff(render(graph), render(loaded))).to eq(0)
      expect(io.dump(loaded, name: 'clips').sub(/saved: "[^"]*"/, '')).to eq(doc.sub(/saved: "[^"]*"/, ''))
    end
  end

  it "saves a captured clip as its events, with its name, performed (its velocities as played)" do
    e = ->(pos, type, note, vel) { [pos, MB::Sound::MIDI::Event.new(type: type, channel: 0, note: note, velocity: vel)] }
    clip = MB::Sound::MIDI::Capture.clip([
      e.(0r, :note_on, 60, 100 / 127.0), e.(1/8r, :note_off, 60, 0.0),
      e.(1/4r, :note_on, 67, 0.5), e.(3/8r, :note_off, 67, 0.0),
      e.(1/2r, :note_on, 64, 0.5),
    ], from: 0, length: 1).named(:lead_1)
    graph = clip.tone.ramp
    doc = io.dump(graph)
    expect(doc).to include(<<~RUBY.chomp)
      events(
        [0r, 1r/8, 60, 0.7874015748031497],
        [1r/4, 1r/8, 67, 0.5],
        [1r/2, 31r/64, 64, 0.5],
        length: 1r, loop: true, performed: true
      ).named(:lead_1).tone.ramp
    RUBY
    loaded = io.load(doc)
    expect(RecipeHelpers.max_diff(render(graph), render(loaded))).to eq(0)
    expect(MB::Sound::GraphNode.graph(loaded).grep(MB::Sound::MIDI::ClipSource).map { |s| s.clip.performed? }).to eq([true])
  end

  describe 'seeds: :fresh' do
    # A clip with a pinned seed, one that draws its seed, and a noise tone
    # that draws one
    let(:doc) {
      MB::Sound.seed(1)
      g = MB::Sound.instance_exec {
        (melody(scale(:minor, :a), 8, seed: 3).named(:pinned) | melody(scale(:minor, :a), 8).named(:drawn)).loop.tone + noise
      }
      io.dump(g, name: 'seeds')
    }

    # The seed: values the reloaded graph prints, in order
    def seeds_of(graph)
      graph.to_ruby(seeds: true).scan(/seed: (\d+)/).flatten.map(&:to_i)
    end

    it 'marks drawn seeds and leaves seeds the code gave as they were written' do
      expect(doc).to start_with("# mb-sound graph document").and include("graph #{io::FORMAT},")
      expect(io::FORMAT).to eq(3)
      expect(doc).to include('melody(scale(:minor, A4), 8, seed: 3).named(:pinned)')
      expect(doc).to match(/melody\(scale\(:minor, A4\), 8, seed: drawn_seed\(\d+\)\)\.named\(:drawn\)/)
      expect(doc).to match(/noise\(seed: drawn_seed\(\d+\)\)/)
    end

    it 'redraws only the drawn seeds, keeping a pinned clip seed' do
      saved = seeds_of(io.load(doc))
      expect(saved.length).to eq(3)
      expect(saved).to include(3)

      MB::Sound.seed(10)
      a = seeds_of(io.load(doc, seeds: :fresh))
      b = seeds_of(io.load(doc, seeds: :fresh))
      [a, b].each do |fresh|
        expect(fresh.length).to eq(3)
        expect(fresh).to include(3)
        expect(fresh - [3]).not_to include(*(saved - [3]))
      end
      expect(a - [3]).not_to eq(b - [3])
    end

    it 'keeps every seed with seeds: :saved, also after saving the loaded graph again' do
      MB::Sound.seed(10)
      loaded = io.load(doc)
      expect(io.load(doc).then { |g| seeds_of(g) }).to eq(seeds_of(loaded))
      expect(RecipeHelpers.max_diff(render(io.load(doc), buffers: 8), render(loaded, buffers: 8))).to eq(0)
      # Drawn seeds stay marked as drawn through a load and a save
      expect(io.dump(loaded, name: 'seeds').sub(/saved: "[^"]*"/, '')).to eq(doc.sub(/saved: "[^"]*"/, ''))
    end

    it 'redraws every seed of documents that don\'t mark them (format 1, or text without a header)' do
      legacy = doc.gsub(/drawn_seed\((\d+)\)/, '\\1').sub("graph #{io::FORMAT},", 'graph 1,')
      saved = seeds_of(io.load(legacy))
      expect(saved).to include(3)
      fresh = seeds_of(io.load(legacy, seeds: :fresh))
      expect(fresh.length).to eq(3)
      expect(fresh & saved).to eq([])

      bare = doc.lines.drop_while { |l| !l.start_with?('graph') }.drop(1).join.gsub(/drawn_seed\((\d+)\)/, '\\1')
      expect(seeds_of(io.load(bare, seeds: :fresh)) & saved).to eq([])
    end

    it 'runs as plain Ruby too (drawn_seed returns its seed)' do
      expect(MB::Sound.drawn_seed(42)).to eq(42)
    end

    it 'takes drawn_seed only as a seed: value' do
      expect { io.load("graph 2
220.hz.ramp.at(drawn_seed(3))") }.to raise_error(io::LoadError, /drawn_seed\(n\) goes only in seed:/)
      expect { io.load("graph 2
noise(seed: drawn_seed(1.5))") }.to raise_error(io::LoadError, /drawn_seed takes an Integer/)
    end
  end

  it "can't save a clip without a recipe that varies per cycle" do
    c = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8
    varied = MB::Sound::Sequence::Clip.new(c.events, length: c.length, loop: true, variations: [MB::Sound::Sequence::Clip::Variation.new(name: 'mine', block: ->(ev, _, _) { ev })])
    expect { io.dump(varied.tone) }.to raise_error(io::DumpError, /per-cycle variations \(mine\)/)
  end

  describe 'events' do
    it 'makes a clip of explicit events' do
      c = MB::Sound.events([0r, 1/8r, 57, 0.75], [1/4r, 1/8r, 60, 1.0, { accented: true, condition: [2, 1] }], length: 1/2r, loop: true)
      expect(c.events).to eq([ev(0r, 1/8r, 57), ev(1/4r, 1/8r, 60, 1.0, accented: true, condition: [2, 1])])
      expect(c.length).to eq(1/2r)
      expect(c).to be_looping
      expect(MB::Sound.events([0, 1/4r, 60, 1], length: 1.bar).length).to eq(1r)
    end

    it 'checks its rows' do
      expect { MB::Sound.events([0, 1/4r, 60]) }.to raise_error(ArgumentError, /Event rows are Arrays/)
      expect { MB::Sound.events([0.5, 1/4r, 60, 1]) }.to raise_error(ArgumentError, /whole notes/)
      expect { MB::Sound.events([0, 1/4r, 60, 1, { loud: true }]) }.to raise_error(ArgumentError, /Unknown event marks :loud/)
      expect { MB::Sound.events([0, -1/4r, 60, 1]) }.to raise_error(ArgumentError, /negative/)
    end
  end
end
