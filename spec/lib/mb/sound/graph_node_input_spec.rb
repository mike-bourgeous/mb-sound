RSpec.describe(MB::Sound::GraphNodeInput, :aggregate_failures) do
  describe '#initialize' do
    it 'accepts an Array of nodes' do
      gni = MB::Sound::GraphNodeInput.new([1.constant, 2.constant])
      expect(gni.read(1)).to eq([Numo::SFloat[1], Numo::SFloat[2]])
    end

    it 'accepts a variable argument list of nodes' do
      gni = MB::Sound::GraphNodeInput.new(1.constant, 2.constant)
      expect(gni.read(1)).to eq([Numo::SFloat[1], Numo::SFloat[2]])
    end

    it 'uses graph node samplers to support parallel branches' do
      graph = 24000.hz.square.at(1)
      gni = [graph, graph, graph, graph].as_input
      expect(gni.read(1)).to eq([Numo::SFloat[1]] * 4)
      expect(gni.sources.values).to all(be_a(MB::Sound::GraphNode::Tee::Branch))
    end
  end

  describe '#read' do
    context 'with a single node' do
      it 'returns output from a node' do
        expect(1.constant.as_input(buffer_size: 5).read(5)).to eq([Numo::SFloat.ones(5)])
      end

      it 'replicates node to requested number of channels' do
        expect(-1.constant.as_input(2, buffer_size: 3).read(2)).to eq([-Numo::SFloat.ones(2)] * 2)
        expect(-1.constant.as_input(3, buffer_size: 3).read(2)).to eq([-Numo::SFloat.ones(2)] * 3)
      end
    end

    context 'with multiple nodes' do
      let(:a) { 1.constant }
      let(:b) { 2.constant }
      let(:inp) { [a, b].as_input }

      it 'returns output from multiple nodes' do
        expect([a, b].as_input.read(4)).to eq([Numo::SFloat[1,1,1,1], Numo::SFloat[2,2,2,2]])
      end

      it 'pads short reads to maximum length or requested count' do
        # Need to stub the tee branches from get_sampler for controlling response lengths
        expect(inp.sources.values[0]).to receive(:sample).exactly(3).times.and_return(Numo::SFloat[1,1,1])
        expect(inp.sources.values[1]).to receive(:sample).exactly(3).times.and_return(Numo::SFloat[2,2,2,2])

        expect(inp.read(2)).to eq([Numo::SFloat[1,1,1,0], Numo::SFloat[2,2,2,2]])
        expect(inp.read(4)).to eq([Numo::SFloat[1,1,1,0], Numo::SFloat[2,2,2,2]])
        expect(inp.read(6)).to eq([Numo::SFloat[1,1,1,0,0,0], Numo::SFloat[2,2,2,2,0,0]])
      end

      it 'replaces partial nil reads with zeros' do
        expect(a).to receive(:sample).and_return(Numo::SFloat[1,2,3])
        expect(b).to receive(:sample).and_return(nil)

        expect(inp.read(3)).to eq([Numo::SFloat[1,2,3], Numo::SFloat[0,0,0]])
      end

      it 'returns nil when all inputs return nil' do
        expect(a).to receive(:sample).twice.and_return(nil)
        expect(b).to receive(:sample).twice.and_return(Numo::SFloat[1,2,3], nil)

        expect(inp.read(4)).to eq([Numo::SFloat[0,0,0,0], Numo::SFloat[1,2,3,0]])
        expect(inp.read(4)).to eq(nil)
      end

      it 'returns nil when all inputs return empty' do
        expect(inp.sources.values[0]).to receive(:sample).and_return(nil)
        expect(inp.sources.values[1]).to receive(:sample).and_return(Numo::SFloat[])

        expect(inp.read(4)).to eq(nil)
      end

      it 'replicates nodes to fill channel count' do
        inp2 = [a, b].as_input(5)
        expect(inp2.read(2)).to eq([Numo::SFloat[1, 1], Numo::SFloat[2, 2], Numo::SFloat[1, 1], Numo::SFloat[2, 2], Numo::SFloat[1, 1]])
      end
    end
  end

  describe '#sources' do
    it 'returns branches that lead to the given nodes' do
      a = 1.constant
      b = 1.5.constant
      inp = [a, b].as_input

      expect(inp.sources.values).to all(be_a(MB::Sound::GraphNode::Tee::Branch))

      root_sources = inp.sources.map { |_, src| MB::Sound::GraphNode.climb_tee_tree(src) }
      expect(root_sources).to eq([a, b])
    end
  end

  describe '#graph' do
    it 'includes the root sources' do
      a = 1.constant
      b = 2.constant
      inp = [a, b].as_input
      expect(inp.graph).to include(a, b)
    end

    it 'can skip tees' do
      a = 1.constant
      b = 2.constant
      inp = [a, b].as_input
      expect(inp.graph(include_tees: false)).to eq([a, 1, b, 2])
    end
  end

  describe '#graph_ranks' do
    it 'returns an array of arrays' do
      expect([1.constant, 2.constant].as_input.graph_ranks).to all(be_a(Array))
    end

    it 'can skip tees' do
      inp = [1.constant, 2.constant].as_input
      graph = inp.graph_ranks(include_tees: false).flatten - [inp]
      expect(graph.length).to eq(2)
      expect(graph).to all(be_a(MB::Sound::GraphNode::Constant))
    end

    pending 'more tests'
  end

  describe '#graph_edges' do
    it 'returns a hash from node to a set of node/name pairs' do
      a = 1.constant + 3.constant
      b = 2.constant
      inp = [a, b].as_input

      expect(inp.graph_edges.keys).to all(be_a(MB::Sound::GraphNode).or be_a(Numeric))
      expect(inp.graph_edges.values).to all(be_a(Set).and all(be_a(Array).and match([respond_to(:graph), be_a(Symbol)])))
    end

    pending 'more tests'
  end

  describe '#spy' do
    it 'adds a block that receives each output buffer' do
      inp = [1.constant, 1i.constant].as_input

      spy_output = []
      inp.spy do |*d|
        spy_output << d
      end

      # TODO: should this be converting to real values?
      expect(inp.read(1)).to eq([Numo::SFloat[1], Numo::SComplex[1i]])
      expect(inp.read(2)).to eq([Numo::SFloat[1, 1], Numo::SComplex[1i, 1i]])
      expect(spy_output).to eq([
        [Numo::SFloat[1], Numo::SComplex[1i]],
        [Numo::SFloat[1, 1], Numo::SComplex[1i, 1i]],
      ])
    end

    pending 'with a handle'
  end

  pending '#clear_spies'
end
