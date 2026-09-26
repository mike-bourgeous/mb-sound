RSpec.describe(MB::Sound::GraphNode::MixSource) do
  let(:source) { MB::Sound::GraphNode::MixSource.new(channels: 2, sample_rate: 44100) }
  let(:data) { [Numo::SFloat[1, 2, 3], Numo::SFloat[-1, -2, -3]] }

  it 'returns each channel of the latest buffer' do
    source.write(data)
    expect(source.outputs.map { |c| c.sample(3) }).to eq(data)

    source.write([Numo::SFloat[4, 5, 6], Numo::SFloat[7, 8, 9]])
    expect(source.outputs[1].sample(3)).to eq(Numo::SFloat[7, 8, 9])
  end

  it 'returns copies so graphs can sample a channel twice and modify the result' do
    source.write(data)
    a = source.outputs[0].sample(3)
    a.inplace * 10
    expect(source.outputs[0].sample(3)).to eq(data[0])
    expect(data[0]).to eq(Numo::SFloat[1, 2, 3])
  end

  it 'works as the start of a graph' do
    chain = source.outputs[0] * 2 + 1
    source.write(data)
    expect(chain.sample(3)).to eq(Numo::SFloat[3, 5, 7])
    expect(chain.graph).to include(source.outputs[0])
    expect(source.outputs[0].original_source).to equal(source)
  end

  it 'raises an error if the chain asks for a different sample count' do
    source.write(data)
    expect { source.outputs[0].sample(4) }.to raise_error(ArgumentError, /asked for 4 samples.*has 3/)
  end

  it 'raises an error if given the wrong number of channels' do
    expect { source.write([data[0]]) }.to raise_error(ArgumentError, /Expected 2 channels/)
  end

  it 'has a fixed sample rate' do
    expect(source.outputs[0].sample_rate).to eq(44100)
    expect { source.outputs[0].at_rate(44100) }.not_to raise_error
    expect { source.outputs[0].at_rate(48000) }.to raise_error(NotImplementedError, /sample rate/)
  end
end
