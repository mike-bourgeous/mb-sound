RSpec.describe(MB::Sound::GraphNode::MathFunction, :aggregate_failures) do
  let(:data) { Numo::SFloat[-1.5, -0.5, 0.25, 0.5, 1.75, 8] }
  let(:input) { MB::Sound::ArrayInput.new(data: [data]) }

  {
    floor: ->(d) { d.floor },
    ceil: ->(d) { d.ceil },
    round: ->(d) { d.round },
  }.each do |name, expected|
    it "##{name} rounds every sample" do
      node = input.send(name)
      expect(node).to be_a(described_class)
      expect(node.sample(6)).to eq(expected.call(data))
    end
  end

  it 'takes logarithms (#log, #log2, #log10)' do
    d = Numo::SFloat[1, 2, 8, 100]
    expect(MB::Sound::ArrayInput.new(data: [d]).log.sample(4)).to all_be_within(1e-6).of_array(Numo::NMath.log(d))
    expect(MB::Sound::ArrayInput.new(data: [d]).log2.sample(4)).to all_be_within(1e-6).of_array(Numo::SFloat[0, 1, 3, Math.log2(100)])
    expect(MB::Sound::ArrayInput.new(data: [d]).log10.sample(4)).to all_be_within(1e-6).of_array(Numo::SFloat[0, Math.log10(2), Math.log10(8), 2])
  end

  it 'leaves a shared input buffer alone and ends with its input' do
    a, b = input.tee
    f = a.floor
    expect(f.sample(6)).to eq(data.floor)
    expect(b.sample(6)).to eq(data)
    expect(f.sample(6)).to be_nil
  end

  it 'describes its function' do
    expect(input.floor.to_s).to match(/floor\(/)
    expect(input.log10.to_s_graphviz).to match(/log10\(/)
    expect { described_class.new(input, function: :sqrt) }.to raise_error(ArgumentError, /sqrt/)
  end

  it 'prints back as Ruby' do
    expect((1.hz.aramp.at(0..4) * 0.9999).floor.to_ruby).to include('.floor')
  end
end
