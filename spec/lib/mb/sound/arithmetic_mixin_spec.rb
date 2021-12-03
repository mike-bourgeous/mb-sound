# Tests for the DSL overall, including Tone, Mixer, Multiplier
RSpec.describe(MB::Sound::ArithmeticMixin) do
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
    expect(graph.cutoff).to be_a(MB::Sound::ArithmeticMixin)
    expect(graph.quality).to be_a(MB::Sound::ArithmeticMixin)

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
end
