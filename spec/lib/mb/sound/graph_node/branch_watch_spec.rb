RSpec.describe(MB::Sound::GraphNode::BranchWatch) do
  it 'stays current while other Tees gain branches, and not once a watched Tee does' do
    tee = 1.hz.sine.get_sampler.owner_tee
    watch = described_class.new([tee, tee])
    expect(watch.tees.length).to eq(1)
    expect(watch.current?).to eq(true)

    other = MB::Sound::GraphNode::Tee.new(2.hz.sine)
    version = other.branch_version
    other.add_branch
    expect(other.branch_version).to eq(version + 1)
    expect(watch.current?).to eq(true)

    b = tee.add_branch
    expect(watch.current?).to eq(false)
    watch = described_class.new([tee])
    b.destroy
    expect(watch.current?).to eq(false)
  end
end

RSpec.describe(MB::Sound::GraphNode, '.structure_changes') do
  it 'counts structural changes to watched nodes only' do
    watched = 1.hz.sine.filter(:lowpass, cutoff: 500)
    unwatched = 2.hz.sine.filter(:lowpass, cutoff: 500)
    MB::Sound::GraphNode.watch_structure(watched.graph)
    before = MB::Sound::GraphNode.structure_changes
    MB::Sound::Plan.changed(unwatched)
    MB::Sound::Plan.changed(watched, structure: false)
    expect(MB::Sound::GraphNode.structure_changes).to eq(before)
    MB::Sound::Plan.changed(watched)
    expect(MB::Sound::GraphNode.structure_changes).to eq(before + 1)
  end
end

# Caches keyed on the global count alone are rebuilt whenever any graph
# anywhere gains a branch (ux-fix-2); they go through BranchWatch.
RSpec.describe('Tee.branch_changes users') do
  it 'are only Tee and BranchWatch' do
    root = File.expand_path('../../../../../lib', __dir__)
    users = Dir[File.join(root, '**/*.rb')].select { |f| File.read(f).match?(/^[^#]*\bbranch_changes\b/) }.map { |f| f.delete_prefix(root + '/') }
    expect(users).to match_array(['mb/sound/graph_node/tee.rb', 'mb/sound/graph_node/branch_watch.rb'])
  end
end
