RSpec.describe(MB::Sound::GraphNode::Nameable) do
  let(:obj) { 'Test'.tap { |o| o.extend(MB::Sound::GraphNode::Nameable) } }

  it 'allows an object to be named' do
    expect(obj.named?).to eq(false)
    expect(obj.named(5).named?).to eq(true)
    expect(obj.name_or_id).to eq('5')
  end
end
