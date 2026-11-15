# Graph drawings by rank (racks phase V, design/notes/drawing.md): the
# generic Plot::Graph layout and text, and Plot.graph's walk of node
# graphs, over every graph sweep factory.
require_relative '../../../../support/graph_sweep'

RSpec.describe(MB::Sound::Plot::Graph) do
  g = MB::Sound::Plot::Graph

  let(:example) {
    g.new(
      boxes: [
        g::Box.new(title: 'saw'),
        g::Box.new(title: 'lfo'),
        g::Box.new(title: 'filter', ins: [g::Slot.new(name: :input), g::Slot.new(name: :cutoff, type: :control), g::Slot.new(name: :quality, type: :control, value: '0.7')]),
        g::Box.new(title: 'y', ins: [g::Slot.new(name: :loop, feedback: true)]),
        g::Box.new(title: '+', ins: [g::Slot.new(name: :input_1), g::Slot.new(name: :input_2)]),
      ],
      wires: [
        g::Wire.new(from: 0, to: 2), g::Wire.new(from: 1, to: 2, in: 1, type: :control),
        g::Wire.new(from: 2, to: 4), g::Wire.new(from: 3, to: 4, in: 1), g::Wire.new(from: 4, to: 3, feedback: true),
      ],
      title: 'example',
    )
  }

  # Checks a drawing's invariants: boxes inside and apart, titles in their
  # top rules, an arrowhead on every wired input slot.
  def check_drawing(d, where)
    text = d.lines(color: :none)
    w, h = d.size
    expect(text.length).to eq(h), where
    d.placements.each_with_index do |p, i|
      expect(p.x).to be >= 0, where
      expect(p.x + p.w).to be <= w, where
      expect(p.y + p.h).to be <= h, where
      title = MB::Sound::Plot::Graph.clip(d.boxes[i].title, MB::Sound::Plot::Graph::MAX_TITLE)
      expect(text[p.y][p.x + 2, title.length]).to eq(title), "#{where}: box #{i} #{title.inspect}" unless title.empty?
    end
    owner = {}
    d.placements.each_with_index do |p, i|
      p.h.times do |r|
        p.w.times do |c|
          other = owner[[p.x + c, p.y + r]]
          raise "#{where}: boxes #{other} and #{i} overlap" if other

          owner[[p.x + c, p.y + r]] = i
        end
      end
    end
    d.wires.each do |wire|
      p = d.placements[wire.to]
      expect(text[p.y + 1 + wire.in][p.x]).to eq('▸'), "#{where}: wire #{wire.inspect}"
    end
  end

  it 'draws a small graph by rank: inputs left, typed wires, an inline value, feedback under the boxes' do
    expect(example.to_s(color: :none)).to eq(<<~TEXT.chomp)
      example
      ┌ saw ┐    ┌ filter ───┐   ┌ + ────┐
      │     ├────▸input      ├───▸input_1├═╗
      └─────┘  ┌┄▸cutoff     │ ┌─▸input_2│ ║
               ┆ │quality 0.7│ │ └───────┘ ║
      ┌ lfo ┐  ┆ └───────────┘ │           ║
      │     ├┄┄┘               │           ║
      └─────┘    ┌ y ─┐        │           ║
              ╔══▸loop├────────┘           ║
              ║  └────┘                    ║
              ║                            ║
              ╚════════════════════════════╝
    TEXT
    expect(example.columns).to eq([[0, 1], [2, 3], [4]])
    expect(example.size).to eq([39, 12])
  end

  it 'draws the same layout in ASCII' do
    ascii = example.lines(color: :none, glyphs: :ascii)
    expect(ascii[2]).to eq('|     +---->input      +--->input_1+=+')
    expect(ascii.join).to match(/\A[ -~]*\z/)
    expect(ascii.map(&:length)).to eq(example.lines(color: :none).map(&:length))
  end

  it 'is frozen and Ractor-shareable' do
    expect(example).to be_frozen
    expect(Ractor.shareable?(example)).to eq(true)
  end

  it 'colors wires by type through UI roles, or none' do
    colored = example.to_s(color: :truecolor)
    expect(colored).to include("\e[")
    expect(MB::Sound::Plot::AnsiHtml).to respond_to(:page)
    plain = example.to_s(color: :none)
    expect(plain).not_to include("\e[")
    feedback = MB::Term::Cells.pack(MB::Sound::Plot::Graph.role_rgb(:warn))
    grid = MB::Term::Cells.new(39, 12)
    example.draw(grid, x: 0, y: 0)
    x = example.lines(color: :none)[2].index('═')
    expect(grid.char(x, 2)).to eq('═')
    expect(grid.instance_variable_get(:@fg)[2 * 39 + x]).to eq(feedback)
  end

  it 'draws a window of the drawing into a grid at an offset, clipped' do
    grid = MB::Term::Cells.new(20, 5)
    example.draw(grid, x: 2, y: 1, w: 12, h: 3, scroll: [9, 1], color: false)
    full = example.lines(color: :none)
    got = grid.lines(:none)
    3.times { |r| expect(got[1 + r][2, 12].rstrip).to eq(full[1 + r][9, 12].to_s.rstrip) }
    expect(got[0].strip).to eq('')
    expect(got[4].strip).to eq('')
  end

  it 'saves text, ANSI, and HTML' do
    expect(File.read(example.save(tmp_path('g.txt')))).to eq(example.to_s(color: :none) + "\n")
    expect(File.read(example.save(tmp_path('g.ans')))).to include("\e[")
    expect(File.read(example.save(tmp_path('g.html')))).to include('<html')
    expect { example.save(tmp_path('g.svg')) }.to raise_error(ArgumentError, /\.txt, \.ans, \.html/)
  end

  it 'routes a wire that skips columns through placeholders, dimmed' do
    d = g.new(
      boxes: [g::Box.new(title: 'a'), g::Box.new(title: 'b', ins: [g::Slot.new(name: :input)]), g::Box.new(title: 'c', ins: [g::Slot.new(name: :x), g::Slot.new(name: :y)])],
      wires: [g::Wire.new(from: 0, to: 1), g::Wire.new(from: 1, to: 2), g::Wire.new(from: 0, to: 2, in: 1)],
    )
    expect(d.columns).to eq([[0], [1], [2]])
    check_drawing(d, 'skip')
    grid = MB::Term::Cells.new(*d.size)
    d.draw(grid, x: 0, y: 0)
    dim = MB::Term::Cells.pack(MB::Sound::Plot::Graph.role_rgb(:dim))
    p = d.placements[2]
    expect(grid.instance_variable_get(:@fg)[(p.y + 2) * d.width + p.x - 1]).to eq(dim)
  end

  it 'draws a cycle among forward wires as feedback' do
    d = g.new(
      boxes: [g::Box.new(title: 'a', ins: [g::Slot.new(name: :input)]), g::Box.new(title: 'b', ins: [g::Slot.new(name: :input)])],
      wires: [g::Wire.new(from: 0, to: 1), g::Wire.new(from: 1, to: 0)],
    )
    check_drawing(d, 'cycle')
    expect(d.to_s(color: :none)).to include('═')
  end

  it 'rejects wires to slots that are not there' do
    expect {
      g.new(boxes: [g::Box.new(title: 'a'), g::Box.new(title: 'b', ins: [])], wires: [g::Wire.new(from: 0, to: 1)])
    }.to raise_error(ArgumentError, /input slot/)
  end

  describe 'Plot.graph' do
    def titles(d) = d.boxes.map(&:title)

    it 'folds Tees, shows constants inline, and leaves out a sum\'s 0 and a product\'s 1' do
      saw = 110.hz.saw
      graph = saw.filter(:lowpass, cutoff: 1200) + saw * 0.5
      d = MB::Sound::Plot.graph(graph)
      expect(titles(d).count('saw')).to eq(1)
      saw_box = titles(d).index('saw')
      expect(d.wires.count { |w| w.from == saw_box }).to eq(2)
      filter = d.boxes.find { |b| b.title == 'filter' }
      expect(filter.ins.find { |s| s.name == :cutoff }.value).to eq('1200 Hz')
      sum = d.boxes.find { |b| b.title == '+' }
      expect(sum.ins.map(&:name)).not_to include(:constant)
      expect(d.boxes.find { |b| b.title == '×' }.ins.map(&:value)).to include('0.5')
      check_drawing(d, 'tees')
    end

    it 'types wires: an LFO into a cutoff is control, notes into a gate are notes' do
      d = MB::Sound::Plot.graph(110.hz.saw.filter(:lowpass, cutoff: 3.hz.lfo.at(200..900)))
      filter = titles(d).index('filter')
      cut = d.wires.find { |w| w.to == filter && d.boxes[filter].ins[w.in].name == :cutoff }
      expect(cut.type).to eq(:control)
      expect(d.to_s(color: :none)).to include('┄')

      gate = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.loop.notes.gate
      n = MB::Sound::Plot.graph(gate)
      expect(n.wires.map(&:type)).to include(:notes)
      expect(n.to_s(color: :none)).to include('╌')
    end

    it 'fans the outputs of a multi-output node from one box' do
      bundle = MB::Sound.stereo(110.hz.saw, 165.hz.saw).compress(threshold: -20.db)
      d = MB::Sound::Plot.graph(bundle.mono)
      multi = d.boxes.each_index.select { |i| d.boxes[i].outs.length > 1 }
      expect(multi).not_to be_empty
      expect(d.wires.select { |w| multi.include?(w.from) }.map(&:out).uniq.sort).to eq([0, 1])
      expect(d.boxes[multi[0]].title).to eq('compress')
      check_drawing(d, 'multi-output')

      # a rack's out box gets each channel
      r = MB::Sound.arack { |sig| MB::Sound.stereo(sig, sig * 0.5).compress(threshold: -20.db) }
      out = r.draw.boxes.find { |b| b.kind == :out }
      expect(out.ins.map(&:name)).to eq([:in_1, :in_2])
    end

    it "draws a feedback loop's variable fed back from its loop" do
      d = MB::Sound::Plot.graph(110.hz.saw.feedback { |fb, x| x + fb.delay(0.01) * 0.5 })
      fb = d.wires.select(&:feedback)
      expect(fb).not_to be_empty
      expect(d.boxes[fb[0].to].ins[fb[0].in].feedback).to eq(true)
      expect(d.to_s(color: :none)).to include('═')
      check_drawing(d, 'feedback loop')
    end

    it 'is what node.draw returns' do
      node = 110.hz.saw.lp4(1200)
      expect(node.draw).to be_a(MB::Sound::Plot::Graph)
      expect(node.draw.to_s(color: :none)).to eq(MB::Sound::Plot.graph(node).to_s(color: :none))
      expect(MB::Sound.seq(MB::Sound::C4).n8.loop.stream.draw.boxes.length).to be >= 1
    end

    it 'stops at max_boxes and says how many it left out' do
      node = (1..12).reduce(110.hz.saw) { |n, k| n.filter(:lowpass, cutoff: 3.hz.lfo.at(200..(900 + k))) }
      d = MB::Sound::Plot.graph(node, max_boxes: 5)
      expect(d.boxes.length).to eq(5)
      expect(d.note).to match(/more nodes? not drawn: max_boxes 5/)
      expect(d.to_s(color: :none)).to include('…')
    end

    it 'lays out and draws every node of every graph sweep factory' do
      checked = 0
      classes = Set.new
      GraphSweep.factories.each do |name, factory|
        MB::Sound.seed(1)
        graph = factory.call(GraphSweep::Context.new)
        d = MB::Sound::Plot.graph(graph)
        expect(d.boxes).not_to be_empty, name
        expect(d.boxes.map(&:title)).to all(match(/\S/)), name
        expect(d.boxes.map(&:title).grep(/MB::|#</)).to eq([]), "#{name}: titles are DSL words, never class names"
        check_drawing(d, name)
        expect(Ractor.shareable?(d)).to eq(true), name
        checked += 1
        graph.graph.each { |n| classes << n.class } if graph.respond_to?(:graph)
      end
      expect(checked).to be > 250
      expect(classes.length).to be > 80
    end
  end

  describe 'rack drawings' do
    after { MB::Sound.rewind }

    let(:dub) {
      MB::Sound.arack(side: :audio) do |sig, side:|
        space = MB::Sound.knob :space, 0.35
        sig.duck(side).delay(0.1, feedback: space * 0.7, wet: space)
      end
    }

    it "draws a rack's ports at the left edge and out at the right" do
      d = dub.draw
      expect(d.title).to eq('anonymous arack: audio(sig) + audio(side) -> ?')
      ports = d.boxes.each_index.select { |i| d.boxes[i].kind == :port }
      expect(ports.map { |i| d.boxes[i].title }).to contain_exactly('sig', 'side')
      expect(ports.map { |i| d.placements[i].col }.uniq).to eq([0])
      out = d.boxes.index { |b| b.kind == :out }
      expect(d.placements[out].col).to eq(d.placements.map(&:col).max)
      expect(d.boxes.map(&:title)).to include('duck', 'knob space')
      check_drawing(d, 'dub')
    end

    it 'gives RackInfo a frozen drawing of the rack, built once' do
      info = dub.info
      expect(info.graph).to be_a(MB::Sound::Plot::Graph)
      expect(info.graph).to equal(dub.graph)
      expect(Ractor.shareable?(info)).to eq(true)
      expect(info.graph.boxes.count { |b| b.kind == :port }).to eq(2)
    end

    it "leaves RackInfo#graph nil when the rack can't build on stand-ins" do
      bad = MB::Sound.arack { |_sig| raise 'no stand-ins here' }
      expect(bad.graph).to be_nil
      expect(bad.info.graph).to be_nil
      expect { bad.draw }.to raise_error(RuntimeError, /no stand-ins/)
    end
  end
end
