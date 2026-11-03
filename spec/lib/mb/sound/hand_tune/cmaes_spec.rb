# CMA-ES ported from the voice-match study (hand-tune-2): the same seed
# gives the research code's populations.  The numbers are the research
# code's own (research-voice-match 6ea917e0, research/voice-match/cmaes.rb,
# run on the same start), so the port stays operation for operation.
RSpec.describe(MB::Sound::HandTune::CMAES) do
  it "draws the research code's first population for the same seed and start" do
    es = described_class.new([0.3, 0.6, 0.1], sigma: 0.3, seed: 7)
    expect(es.lambda).to eq(7)
    expect(es.ask.first).to eq([0.4271794517743559, 0.5360646910878639, 0.03854840470806896])
  end

  it 'moves toward the minimum and shrinks its step' do
    es = described_class.new([0.9, 0.9], sigma: 0.3, seed: 1)
    60.times {
      pop = es.ask
      es.tell(pop, pop.map { |x, y| (x - 0.2)**2 + (y - 0.4)**2 })
    }
    expect(es.mean[0]).to be_within(1e-3).of(0.2)
    expect(es.mean[1]).to be_within(1e-3).of(0.4)
    expect(es.sigma).to be < 0.05
  end

  it 'finds the eigenvalues of a symmetric matrix' do
    vals, vecs = described_class.jacobi([[2.0, 1.0], [1.0, 2.0]])
    expect(vals.sort).to all(be_a(Float))
    expect(vals.sort[0]).to be_within(1e-12).of(1.0)
    expect(vals.sort[1]).to be_within(1e-12).of(3.0)
    expect(vecs.flatten.map(&:abs)).to all(be_within(1e-12).of(Math.sqrt(0.5)))
  end
end
