RSpec.describe(MB::Sound::GraphNode::Quantize, :aggregate_failures) do
  let (:data1) { MB::Sound::ArrayInput.new(data: Numo::SFloat[0.49, 0.5, 0.51, -0.49, -0.5, -0.51]) }
  let (:complex_data) { MB::Sound::ArrayInput.new(data: Numo::DComplex[0.49, 0.5i, 0.51, -0.49i, -0.5, -0.51i, -0.25+0.8i]) }

  it 'can quantize to a numeric increment' do
    expect(data1.dup.aquantize(0.25).sample(6)).to eq(Numo::SFloat[0.5, 0.5, 0.5, -0.5, -0.5, -0.5])
    expect(data1.dup.aquantize(1).sample(6)).to eq(Numo::SFloat[0, 1, 1, 0, -1, -1])
  end

  it 'takes a Rational increment (8-bit steps as 1r/127; protos-1)' do
    expect(data1.dup.aquantize(1r / 4).sample(6)).to eq(Numo::SFloat[0.5, 0.5, 0.5, -0.5, -0.5, -0.5])
    expect(data1.dup.aquantize(1r / 127).sample(6)).to eq(data1.dup.aquantize(1.0 / 127).sample(6))
  end

  it 'does not matter if the quantization increment is negative' do
    expect(data1.dup.aquantize(-0.25).sample(6)).to eq(Numo::SFloat[0.5, 0.5, 0.5, -0.5, -0.5, -0.5])
    expect(data1.dup.aquantize(-1).sample(6)).to eq(Numo::SFloat[0, 1, 1, -0, -1, -1])
  end

  it 'can quantize to another graph node' do
    expect(data1.dup.aquantize(MB::Sound::ArrayInput.new(data: Numo::SFloat[0.33, 0.33, 0.5, 0.5, -1, 1])).sample(6)).to eq(Numo::SFloat[0.33, 0.66, 0.5, -0.5, -1, -1])
  end

  it 'reads an increment node used elsewhere through a Tee branch (textures-4)' do
    # The increment once read the node directly, so a node also read by
    # another consumer advanced twice per buffer and overflowed the Tee of
    # anything upstream shared with a third reader
    w = 0.5.constant
    step = w * 0.01
    graph = (440.hz.sine.at(0.1) + step).quantize(step).filter(:lowpass, cutoff: 9000 - w * 7800)
    expect { 100.times { graph.sample(800) } }.not_to raise_error
  end

  it 'does not quantize if the numeric value is zero' do
    expect(data1.dup.aquantize(0).sample(6)).to eq(data1.dup.sample(6))
  end

  it 'does not quantize if the graph node output is zero' do
    expect(data1.dup.aquantize(MB::Sound::ArrayInput.new(data: Numo::SFloat[0, 0, 0, 1, 1, 0.6])).sample(6)).to eq(Numo::SFloat[0.49, 0.5, 0.51, 0, -1, -0.6])
  end

  it 'can quantize complex inputs' do
    expect(complex_data.dup.aquantize(0.33).sample(7)).to eq(Numo::DComplex[0.33, 0.66i, 0.66, -0.33i, -0.66, -0.66i, -0.33+0.66i])
  end

  # TODO: fix this when nans and infinities are handled correctly in the input data (or should we just let nan and infinity do what they do??)
  pending 'nans and infinities'

  it 'changes the increment sample rate to match the upstream' do
    a = 10.hz.at_rate(1000)
    b = 10.hz.at_rate(1001)
    q = a.aquantize(b)

    expect(a.sample_rate).to eq(1000)
    expect(b.sample_rate).to eq(1000)
    expect(q.sample_rate).to eq(1000)
  end
end
