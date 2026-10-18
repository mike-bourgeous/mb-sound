# Typed ports (racks R1, design/notes/racks.md): every Traversable answers
# #port_info with typed, role-tagged inputs and typed outputs.  The sweep
# part runs over every node of every graph sweep factory.
require_relative '../../../../support/graph_sweep'

RSpec.describe('GraphNode typed ports (#port_info)') do
  types = MB::Sound::GraphNode::Traversable::PORT_TYPES
  roles = [:main, :side, :param, :feedback]

  it 'answers sanely for every node of every graph sweep factory' do
    checked = Set.new
    GraphSweep.factories.each do |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      nodes = graph.respond_to?(:graph) ? graph.graph : []
      nodes.each do |n|
        next unless n.respond_to?(:port_info)

        info = n.port_info
        where = "#{name}: #{n.class}"
        expect(info.keys).to eq([:in, :out]), where
        expect(info[:out]).not_to be_empty, where
        info[:out].each do |o|
          expect(o[:name]).to be_a(Symbol), where
          expect(types).to include(o[:type]), where
        end
        expect(info[:out][0][:type]).to eq(n.port_type), where if info[:out].length == 1

        ins = info[:in].reject { |e| e[:role] == :feedback }
        expect(ins.map { |e| e[:name] }).to eq(n.sources.keys), where
        expect(ins.map { |e| e[:source] }).to eq(n.sources.values), where
        info[:in].each do |e|
          expect(types).to include(e[:type]), "#{where} #{e[:name]}"
          expect(roles).to include(e[:role]), "#{where} #{e[:name]}"
          expect(e[:active]).to eq(true).or(eq(false))
          expect(e[:type]).to eq(:control), "#{where} #{e[:name]}" if e[:role] == :param && MB::Sound::GraphNode::Traversable.port_type_of(e[:source]) != :notes
        end
        checked << n.class
      end
    end
    expect(checked.length).to be > 80
  end

  it 'keeps #sources and #inputs as before' do
    f = 110.hz.saw.filter(:lowpass, cutoff: 800)
    expect(f.inputs).to eq(f.sources)
    expect(f.sources).to be_a(Hash)
  end

  it 'types a filter input as audio and its cutoff as a control parameter' do
    f = 110.hz.saw.filter(:lowpass, cutoff: 3.hz.lfo.at(200..900))
    ins = f.graph.flat_map { |n| n.respond_to?(:port_info) ? n.port_info[:in] : [] }
    cutoff = ins.find { |e| e[:name] == :cutoff }
    input = ins.find { |e| e[:name] == :input && e[:role] == :main && e[:type] == :audio }
    expect(cutoff).to include(type: :control, role: :param)
    expect(input).not_to be_nil
  end

  it 'marks sidechains as side inputs' do
    c = 110.hz.saw.compress(sidechain: 2.hz.saw)
    ins = c.graph.flat_map { |n| n.respond_to?(:port_info) ? n.port_info[:in] : [] }
    side = ins.select { |e| e[:role] == :side }
    expect(side).not_to be_empty
    expect(side.map { |e| e[:type] }.uniq).to eq([:audio])
  end

  it 'types MIDI streams, sources, and transforms as notes' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n8.loop
    s = clip.stream.transpose(12)
    expect(s.port_type).to eq(:notes)
    expect(s.port_info[:out]).to eq([{ name: :out, type: :notes }])
    expect(s.port_info[:in].map { |e| e[:type] }.uniq).to eq([:notes])

    gate = clip.notes.gate
    expect(gate.port_type).to eq(:control)
    expect(gate.port_info[:in]).to include(include(name: :stream, type: :notes, role: :main))
  end

  it 'lists feedback edges with the feedback role' do
    a = 1.constant
    b = 110.hz.saw
    b.with_feedback(fb: a)
    expect(b.port_info[:in].last).to include(name: :fb, role: :feedback, type: :control, source: a)
  end

  it 'lists a multi-output node once per output' do
    st = MB::Sound.stereo(110.hz.saw, 220.hz.saw)
    expect(st.port_info[:out].map { |o| o[:name] }).to eq([:out_1, :out_2])
  end

  it 'types constants and knobs as control outputs' do
    expect(3.constant.port_type).to eq(:control)
    expect(MB::Sound::GraphNode::Traversable.port_type_of(3)).to eq(:control)
    expect(MB::Sound::GraphNode::Traversable.port_type_of(MB::Sound.seq(MB::Sound::C4))).to eq(:notes)
  end
end
