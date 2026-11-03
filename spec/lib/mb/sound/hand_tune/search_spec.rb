# The voice-match study's search loop in lib (hand-tune-2): the same seed
# and budget give the research code's best (its numbers, from
# research-voice-match 6ea917e0's fit.rb on the same synthetic loss), and
# refine's additions (deadline, stop, stages) stop cleanly with the best so
# far.
RSpec.describe(MB::Sound::HandTune::Search, :aggregate_failures) do
  # A multimodal synthetic loss (Rastrigin, shifted per coordinate).
  RASTRIGIN = ->(u) { u.each_with_index.sum { |x, i| z = 6 * (x - 0.37 - 0.05 * i); z * z - 2 * Math.cos(2 * Math::PI * z) + 2 } }
  START = (0...4).map { |i| 0.2 + 0.07 * i }.freeze # (as the research run computed it)

  it "finds the research code's best at the same evaluation, with its history" do
    s = described_class.new(4, &RASTRIGIN)
    best = s.run(START, evals: 600, seed: 3)
    expect(best.f).to eq(0.9765532773048871)
    expect(best.at).to eq(469)
    expect(s.evals).to eq(602)
    expect(best.u).to eq([0.3695989879906304, 0.4200426614008706, 0.47008266670823057, 0.6833900758415633])
    expect(s.history).to eq([[1, 7.98903], [36, 6.28734], [97, 3.18227], [260, 2.90228], [271, 2.38208], [282, 2.32728], [327, 1.80721], [347, 1.61514],
                             [352, 1.14461], [376, 1.13892], [387, 1.08653], [394, 1.00192], [461, 0.99003], [463, 0.98947], [469, 0.97655]])
    expect(s.stopped?).to eq(false)
  end

  it 'is deterministic for a seed, and stops at its stop Proc or deadline keeping the best so far' do
    a = described_class.new(4, &RASTRIGIN)
    a.run(START, evals: 200, seed: 5)
    b = described_class.new(4, &RASTRIGIN)
    b.run(START, evals: 200, seed: 5)
    expect(b.best).to eq(a.best)

    seen = []
    c = described_class.new(4, &RASTRIGIN)
    c.run(START, evals: 600, seed: 5, stop: -> { c.evals >= 37 }, progress: ->(s) { seen << s.evals })
    expect(c.evals).to eq(37)
    expect(c.stopped?).to eq(true)
    expect(seen.last).to eq(37)
    # (the same points as the unstopped run up to there)
    expect(c.history).to eq(a.history.select { |at, _| at <= 37 })

    d = described_class.new(4, &RASTRIGIN)
    d.run(START, evals: 10_000, seed: 5, deadline: MB::U.clock_now - 1)
    expect(d.evals).to eq(0)
    expect(d.best).to be_nil
  end

  it 'moves only its free coordinates (a stage), never ending worse than its start' do
    s = described_class.new(4, &RASTRIGIN)
    start = s.evaluate(START)
    s.run(START, evals: 150, seed: 2, free: [1, 3])
    expect(s.best.f).to be <= start
    expect(s.best.u.values_at(0, 2)).to eq(START.values_at(0, 2))
    expect(s.best.u.values_at(1, 3)).not_to eq(START.values_at(1, 3))
  end

  it 'scores points outside the cube at the clamped point plus a penalty, and failed losses as 1000' do
    s = described_class.new(1) { |u| u[0] }
    expect(s.evaluate([1.5])).to eq(1.0 + 10 * 0.25)
    expect(described_class.new(1) { Float::NAN }.evaluate([0.5])).to eq(1e3)
  end
end
