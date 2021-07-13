RSpec.describe(MB::Sound::SoftestClip) do
  let(:data) { Numo::SFloat.linspace(-3, 3, 101) }

  it 'rejects a limit that is less than the threshold' do
    expect { MB::Sound::SoftestClip.new(threshold: 1, limit: 0.9) }.to raise_error(/limit/i)
  end

  it 'can start the hyperbolic section at 0' do
    c = MB::Sound::SoftestClip.new(threshold: 0, limit: 1)
    expect(c.process([0])[0]).to eq(0)
    expect(c.process([0.001])[0]).to be_between(0, 0.001).exclusive
    expect(c.process([-0.001])[0]).to be_between(-0.001, 0).exclusive
    expect(c.process([100000])[0]).to be_between(0.99, 1).exclusive

    result = c.process(data)
    expect(result.max).to be_between(0.5, 1).exclusive
    expect(result.min).to be_between(-1, -0.5).exclusive

    diff = result.diff
    expect(diff.min).to be > 0
  end

  it 'can be a hard-clip when threshold and limit are the same' do
    c = MB::Sound::SoftestClip.new(threshold: 0.3, limit: 0.3)
    expect(c.process(0.3)).to eq(0.3)
    expect(c.process(0.2)).to eq(0.2)
    expect(c.process(-0.3)).to eq(-0.3)

    result = c.process(data)
    expect(result.min.round(6)).to eq(-0.3)
    expect(result.max.round(6)).to eq(0.3)

    diff = result.diff
    expect(diff.min).to eq(0)
    expect(diff.max).to be > 0
  end

  it 'can use a threshold of 0.25' do
    c = MB::Sound::SoftestClip.new(threshold: 0.25)
    expect(c.process(-10000).round(2)).to eq(-1)
    expect(c.process(-0.5)).to be_between(-0.5, -0.26).exclusive
    expect(c.process(-0.26)).to be_between(-0.26, -0.25).exclusive
    expect(c.process(-0.25)).to eq(-0.25)
    expect(c.process(0)).to eq(0)
    expect(c.process(0.25)).to eq(0.25)
    expect(c.process(0.26)).to be_between(0.25, 0.26).exclusive
    expect(c.process(0.5)).to be_between(0.26, 0.5).exclusive
    expect(c.process(10000).round(2)).to eq(1)

    result = c.process(data)
    expect(result.max).to be_between(0.5, 1).exclusive
    expect(result.min).to be_between(-1, -0.5).exclusive

    diff = result.diff
    expect(diff.min).to be > 0
  end

  it 'can use a threshold of 0.8' do
    c = MB::Sound::SoftestClip.new(threshold: 0.8)
    expect(c.process(-10000).round(2)).to eq(-1)
    expect(c.process(-0.9)).to be_between(-0.9, -0.8).exclusive
    expect(c.process(-0.8)).to eq(-0.8)
    expect(c.process(-0.5)).to eq(-0.5)
    expect(c.process(-0.26)).to eq(-0.26)
    expect(c.process(0)).to eq(0)
    expect(c.process(0.26)).to eq(0.26)
    expect(c.process(0.5)).to eq(0.5)
    expect(c.process(0.8)).to eq(0.8)
    expect(c.process(0.9)).to be_between(0.8, 0.9).exclusive
    expect(c.process(10000).round(2)).to eq(1)

    result = c.process(data)
    expect(result.max).to be_between(0.8, 1).exclusive
    expect(result.min).to be_between(-1, -0.8).exclusive

    # Ensure monotonic increase
    diff = result.diff
    expect(diff.min).to be > 0
  end

  it 'can use a higher limit' do
    c = MB::Sound::SoftestClip.new(threshold: 1, limit: 2)
    expect(c.process(-100000).round(2)).to eq(-2)
    expect(c.process(-1.5)).to be_between(-1.5, -1).exclusive
    expect(c.process(-1)).to eq(-1)
    expect(c.process(1)).to eq(1)
    expect(c.process(1.5)).to be_between(1, 1.5).exclusive
    expect(c.process(100000).round(2)).to eq(2)

    result = c.process(data)
    expect(result.max).to be_between(1.5, 2).exclusive
    expect(result.min).to be_between(-2, -1.5).exclusive

    diff = result.diff
    expect(diff.min).to be > 0
  end

  it 'can use a lower limit' do
    c = MB::Sound::SoftestClip.new(threshold: 0.7, limit: 0.8)
    expect(c.process(-100000).round(2)).to eq(-0.8)
    expect(c.process(-0.75)).to be_between(-0.75, -0.7).exclusive
    expect(c.process(-0.7)).to eq(-0.7)
    expect(c.process(0.7)).to eq(0.7)
    expect(c.process(0.75)).to be_between(0.7, 0.75).exclusive
    expect(c.process(100000).round(2)).to eq(0.8)

    result = c.process(data)
    expect(result.max).to be_between(0.5, 0.8).exclusive
    expect(result.min).to be_between(-0.8, -0.5).exclusive

    diff = result.diff
    expect(diff.min).to be > 0
  end
end
