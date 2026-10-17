# GraphNode.longest_path (racks-r2): path sums over a graph take the same
# edges as GraphNode.graph (through Tees, from multi-output nodes' outputs),
# so walks such as rack latency can't stop short of nodes behind a Tee.
require_relative '../../../../support/graph_sweep'

RSpec.describe('MB::Sound::GraphNode.longest_path') do
  it 'reaches every node .graph lists, for every graph sweep factory' do
    GraphSweep.factories.each do |name, factory|
      MB::Sound.seed(1)
      graph = factory.call(GraphSweep::Context.new)
      roots = graph.is_a?(MB::Sound::GraphNode::Channels) ? graph.to_a : [graph]
      roots.each do |root|
        next unless root.respond_to?(:graph)
        visited = {}.compare_by_identity
        MB::Sound::GraphNode.longest_path(root, visited: visited) { 0 }
        expect(visited.keys.map(&:object_id).sort).to eq(root.graph.uniq.map(&:object_id).sort), name.to_s
      end
    end
  end

  it 'sums weights along the longest path, through Tees' do
    shared = 1.constant.compress(lookahead: 5.ms)
    g = shared * 0.5 + shared.compress(lookahead: 1.ms)
    expect(MB::Sound::Rack.latency_of(g)).to eq(240 + 48)
    expect(MB::Sound::Rack.latency_of([1.constant, 2.constant].channels.limit(lookahead: 1.ms)[0])).to be > 48
  end
end
