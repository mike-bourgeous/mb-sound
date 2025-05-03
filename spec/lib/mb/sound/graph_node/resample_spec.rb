RSpec.describe(MB::Sound::GraphNode::Resample) do
  it 'can be created' do
    expect { MB::Sound::GraphNode::Resample.new(upstream: 150.hz.triangle, sample_rate: 12345) }
  end

  it 'can upsample' do
    resampled = 150.hz.at(1).at_rate(12000).resample(96000).sample(9600)
    reference = 150.hz.at(1).at_rate(96000).sample(9600)

    delta = resampled - reference

    expect(delta.abs.max).to be < 0.1
  end

  pending
end
