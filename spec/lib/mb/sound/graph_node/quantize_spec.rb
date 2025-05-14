RSpec.describe(MB::Sound::GraphNode::Quantize, :aggregate_failures) do
  let (:data1) { MB::Sound::ArrayInput.new(data: Numo::SFloat[0.49, 0.5, 0.51, -0.49, -0.5, -0.51]) }
  let (:complex_data) { MB::Sound::ArrayInput.new(data: Numo::DComplex[0.49, 0.5i, 0.51, -0.49i, -0.5, -0.51i, -0.25+0.8i]) }

  it 'can quantize to a numeric increment' do
    expect(data1.dup.quantize(0.25).sample(6)).to eq(Numo::SFloat[0.5, 0.5, 0.5, -0.5, -0.5, -0.5])
    expect(data1.dup.quantize(1).sample(6)).to eq(Numo::SFloat[0, 1, 1, 0, -1, -1])
  end

  it 'does not matter if the quantization increment is negative' do
    expect(data1.dup.quantize(-0.25).sample(6)).to eq(Numo::SFloat[0.5, 0.5, 0.5, -0.5, -0.5, -0.5])
    expect(data1.dup.quantize(-1).sample(6)).to eq(Numo::SFloat[0, 1, 1, -0, -1, -1])
  end

  it 'can quantize to another graph node' do
    expect(data1.dup.quantize(MB::Sound::ArrayInput.new(data: Numo::SFloat[0.33, 0.33, 0.5, 0.5, -1, 1])).sample(6)).to eq(Numo::SFloat[0.33, 0.66, 0.5, -0.5, -1, -1])
  end

  it 'does not quantize if the numeric value is zero' do
    expect(data1.dup.quantize(0).sample(6)).to eq(data1.dup.sample(6))
  end

  it 'does not quantize if the graph node output is zero' do
    expect(data1.dup.quantize(MB::Sound::ArrayInput.new(data: Numo::SFloat[0, 0, 0, 1, 1, 0.6])).sample(6)).to eq(Numo::SFloat[0.49, 0.5, 0.51, 0, -1, -0.6])
  end

  it 'can quantize complex inputs' do
    expect(complex_data.dup.quantize(0.33).sample(7)).to eq(Numo::DComplex[0.33, 0.66i, 0.66, -0.33i, -0.66, -0.66i, -0.33+0.66i])
  end

  # TODO: fix this when nans and infinities are handled correctly in the input data
  pending 'nans and infinities'

  it 'raises an error if the upstream rate and the increment rate are different' do
    expect { 10.hz.at_rate(1000).quantize(10.hz.at_rate(1001)) }.to raise_error(/sample rate/)
  end
end
