require_relative '../../../../support/synthetic_sounds'

RSpec.describe(MB::Sound::Analysis::Preferences) do
  let(:prefs) { MB::Sound::Analysis::Preferences }

  # A synthetic listener who hears modulation: in every item the pick has
  # the target's AM and the others are closer in spectrum but move wrong.
  let(:items) {
    [[0.5, 220], [0.8, 330], [1.0, 165]].map.with_index { |(depth, hz), i|
      target = SyntheticSounds.tone(hz, 1, harmonics: 8, am: [3, 3 * depth])
      {
        name: "item #{i}",
        target: target,
        candidates: {
          'moves right' => SyntheticSounds.tone(hz, 1, harmonics: 5, am: [3, 3 * depth]),
          'still' => SyntheticSounds.tone(hz, 1, harmonics: 8),
          'too fast' => SyntheticSounds.tone(hz, 1, harmonics: 7, am: [9, 3]),
        },
        pick: 'moves right',
      }
    }
  }

  it 'scores how often each distance ranks the pick first' do
    pr = prefs.new(items)
    rows = pr.evaluate.to_h { |s| [s.name, s] }
    expect(rows.keys).to eq(%w[spectral modulation attack timbre L3])
    expect(rows['modulation'].top1).to eq(3)
    expect(rows['modulation'].pairs_right).to eq(6)
    expect(rows['modulation'].mrr).to eq(1)
    expect(rows['modulation'].p_top1).to be_within(1e-12).of(1 / 27.0)
    expect(rows['spectral'].top1).to be < 3
    expect(rows['modulation'].chance_top1).to eq(1)
    expect(pr.to_s).to include('3 labeled items', 'modulation')
    expect(pr.ranks(:modulation).values).to eq([1, 1, 1])
  end

  it 'takes precomputed scores, weights, and procs, and counts ties as half' do
    pr = prefs.new([
      { scores: { 'a' => { x: 1.0, y: 3.0 }, 'b' => { x: 2.0, y: 1.0 } }, pick: 'a' },
      { scores: { 'a' => { x: 1.0, y: 1.0 }, 'b' => { x: 1.0, y: 2.0 }, 'c' => { x: 0.5, y: 5.0 } }, pick: 'b' },
    ])
    x, y, both, f = pr.evaluate(x: :x, y: :y, both: { x: 1, y: 1 }, f: ->(s) { -s[:x] })
    expect(x.top1).to eq(1)
    expect(x.pairs_right).to eq(1 + 0.5)
    expect(y.top1).to eq(0)
    expect(both.top1).to eq(0)
    expect(f.top1).to eq(0)
    expect(pr.ranks(:x)).to eq('item 1' => 1, 'item 2' => 2.5)
  end

  it 'computes exact p values' do
    expect(prefs.at_least_hits([0.5, 0.5], 2)).to be_within(1e-12).of(0.25)
    expect(prefs.at_least_hits([0.5, 0.5], 1)).to be_within(1e-12).of(0.75)
    expect(prefs.at_least_hits([0.5], 0)).to eq(1.0)
    expect(prefs.at_least_sum([2, 3], 3)).to be_within(1e-12).of(1 / 6.0)
    expect(prefs.at_least_sum([2, 3], 2.5)).to be_within(1e-12).of(1 / 6.0)
    expect(prefs.at_least_sum([3], 1)).to be_within(1e-12).of(2 / 3.0)
  end

  it 'refuses picks that are not candidates' do
    expect { prefs.new([{ scores: { 'a' => { x: 1 }, 'b' => { x: 2 } }, pick: 'c' }]) }.to raise_error(ArgumentError, /pick "c" is not a candidate/)
    expect { prefs.new([{ scores: { 'a' => { x: 1 } }, pick: 'a' }]) }.to raise_error(ArgumentError, /two candidates/)
  end
end
