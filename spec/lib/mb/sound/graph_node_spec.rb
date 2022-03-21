# Tests for the DSL overall, including Tone, Mixer, Multiplier
RSpec.describe(MB::Sound::GraphNode) do
  it 'can create a complex signal graph' do
    graph = (1.hz.square.at_rate(20).at(1) - 2.hz.square.at_rate(20).at(0.5) - 5 + 3 + 2) * 0.5.hz.square.at_rate(20).at(2..1) * 3 + 1
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(2.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(5.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-3.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-0.5))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(4))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(10))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-8))
    expect(graph.sample(5)).to eq(Numo::SFloat.zeros(5).fill(-2))
  end

  it 'can apply softclipping' do
    graph = (1.hz.square.at_rate(20).at(10) + 9.75).softclip(0.5, 1)
    expect(graph.sample(10).mean).to be_between(0.5, 1.0)
    expect(graph.sample(10).mean.round(6)).to eq(-0.25)
  end

  it 'can apply filtering' do
    graph = 400.hz.at(1).filter(400.hz.lowpass(quality: 5))
    expect(graph.sample(48000).max.round(6)).to eq(5)
  end

  it 'can create a dynamic filter' do
    graph = 500.hz.filter(:highpass, cutoff: MB::Sound.adsr(0.2, 0.0, 1.0, 0.75, auto_release: 0.5) * 1000 + 100, quality: MB::Sound.adsr(0.3, 0.3, 1.0, 1.0, auto_release: 0.7) * -5 + 6)

    # Ensure the correct types were created and stored
    expect(graph).to be_a(MB::Sound::Filter::Cookbook::CookbookWrapper)
    expect(graph.audio).to be_a(MB::Sound::Tone)
    expect(graph.cutoff).to be_a(MB::Sound::GraphNode::Mixer)
    expect(graph.quality).to be_a(MB::Sound::GraphNode::Mixer)

    # Ensure 500Hz tone gets quieter as filter frequency rises
    attack = graph.sample(2000).abs.max
    graph.sample(14000)
    sustain = graph.sample(10000).abs.max
    expect(sustain).to be < (0.25 * attack)

    # Expect tone to get louder as frequency falls again
    graph.sample(12000)
    release = graph.sample(2000).abs.max
    expect(release).to be > (1.5 * sustain)
  end

  it 'resets default durations on tones added or multiplied to a graph' do
    graph = (100.hz.for(2) + 33.hz.or_for(0.1) + 25.hz.or_for(0.1) - 11.hz.or_for(0.1)) * 10.hz.or_for(0.1) * 15.hz.or_for(0.1) - 5.hz.or_for(0.1)

    # Expect exactly two full seconds of audio despite potentially shorter tones mixed in
    20.times do
      expect(graph.sample(4800)).to be_a(Numo::SFloat)
    end
    expect(graph.sample(4800)).to eq(nil)
  end

  it 'resets default amplitudes on tones multiplied to a graph' do
    graph = 0.hz.square.at(2) * 0.hz.square.or_at(0) * 0.hz.square.or_at(0)

    # If the amplitude was not reset this would return 0
    expect(graph.sample(100)).to eq(Numo::SFloat.zeros(100).fill(2))
  end

  describe '#coerce' do
    it 'allows signal nodes to be preceded by numeric values in multiplication' do
      expect(5 * 5.constant).to be_a(MB::Sound::GraphNode::Multiplier)
    end

    it 'allows signal nodes to be preceded by numeric values in addition' do
      expect(5 + 5.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end

    it 'allows signal nodes to be preceded by numeric values in subtraction' do
      expect(5 - 5.constant).to be_a(MB::Sound::GraphNode::Mixer)
    end
  end

  describe '#proc' do
    it 'can apply Ruby code within a signal chain' do
      graph = 0.hz.square.at(1).proc { |buf| buf * 3 }
      expect(graph.sample(10)).to eq(Numo::SFloat.new(10).fill(3))
    end
  end

  describe '#spy' do
    it 'calls a block when the sample method is called' do
      b = nil
      p = ->(buf) { b = buf.dup }

      ref = 456.hz.spy(&p).sample(100)
      expect(ref.abs.max).not_to eq(0)
      expect(b).not_to equal(ref)
      expect(b).to eq(ref)
    end

    it 'can call multiple blocks' do
      b = nil
      p = ->(buf) { b = buf.dup }

      absmax = nil
      p2 = ->(buf) { absmax = buf.abs.max }

      ref = 456.hz.spy(&p).spy(&p2).sample(100)
      expect(ref.abs.max).not_to eq(0)
      expect(b).not_to equal(ref)
      expect(b).to eq(ref)
      expect(absmax).to eq(ref.abs.max)
    end
  end

  describe '#clear_spies' do
    it 'does nothing if there are no spies' do
      expect(0.hz.clear_spies.sample(5)).to eq(Numo::SFloat.zeros(5))
    end

    it 'removes active spies' do
      b = nil
      p = ->(buf) { b = buf.dup }

      456.hz.spy(&p).clear_spies.sample(100)
      expect(b).to eq(nil)
    end
  end
end
