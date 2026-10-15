RSpec.describe(MB::Sound::Generative::Dice, :aggregate_failures) do
  let(:dice) { described_class.new(3) }

  around do |ex|
    mode = described_class.mode
    ex.run
  ensure
    described_class.mode = mode
  end

  it 'draws the same numbers whenever they are asked for' do
    a = dice.rand(:kick, 5)
    100.times { |i| dice.rand(:other, i) }
    expect(dice.rand(:kick, 5)).to eq(a)
    expect(described_class.new(3).rand(:kick, 5)).to eq(a)
    expect(described_class.new(4).rand(:kick, 5)).not_to eq(a)
    expect(dice.rand(:kick, 6)).not_to eq(a)
    expect(dice.rand(:hat, 5)).not_to eq(a)
  end

  it 'branches: dice[k].rand(*rest) is dice.rand(k, *rest)' do
    expect(dice[:kick].rand(5)).to eq(dice.rand(:kick, 5))
    expect(dice[:kick][5].rand).to eq(dice.rand(:kick, 5))
    expect(dice[:kick]).to eq(described_class.new(3, :kick))
    expect(dice[:kick].path).to eq([:kick])
    expect(dice[:kick].seed).to eq(3)
    expect(dice[:a].rands(4)).to eq(Array.new(4) { |i| dice.rand(:a, i) })
    expect(dice.to_s).to eq('Dice(3)')
    expect(dice[:a, 2].to_s).to eq('Dice(3, :a, 2)')
  end

  it 'gives the same draws in C and in the Ruby mirror' do
    keys = [[], [:kick], [:kick, 5], ['s', 3r/4, nil, -2], [2**70]]
    c = keys.map { |k| [dice.rand(*k), described_class.new(3, *k).state, dice.int(1..6, *k), dice.pick({ a: 1, b: 2, c: 0.5 }, *k)] }
    described_class.mode = :ruby
    r = keys.map { |k| [dice.rand(*k), described_class.new(3, *k).state, dice.int(1..6, *k), dice.pick({ a: 1, b: 2, c: 0.5 }, *k)] }
    expect(r).to eq(c)
    expect { described_class.mode = :fast }.to raise_error(ArgumentError, /:c, :ruby/)
  end

  it 'draws Integers, chances, and choices' do
    ints = Array.new(3000) { |i| dice.int(1..6, :d, i) }
    expect(ints.uniq.sort).to eq((1..6).to_a)
    expect(Array.new(3000) { |i| dice.int(0...3, :e, i) }.uniq.sort).to eq([0, 1, 2])
    hits = Array.new(5000) { |i| dice.chance(0.3, :c, i) }.count(true)
    expect(hits).to be_within(150).of(1500)
    picks = Array.new(4000) { |i| dice.pick({ a: 3, b: 1, z: 0 }, :p, i) }.tally
    expect(picks.keys.sort).to eq([:a, :b])
    expect(picks[:a].to_f / picks[:b]).to be_within(0.4).of(3)
    expect(Array.new(300) { |i| dice.pick([1, 2, 3], :q, i) }.uniq.sort).to eq([1, 2, 3])
    expect { dice.int(3..1) }.to raise_error(ArgumentError, /range/)
    expect { dice.pick([]) }.to raise_error(ArgumentError, /empty/)
    expect { dice.pick({ a: 0 }) }.to raise_error(ArgumentError, /zero/)
  end

  it 'makes smooth value noise that passes through its whole-number values' do
    expect(dice.smooth(3, :d)).to eq(dice.rand(:d, 3))
    xs = (0..400).map { |i| dice.smooth(i / 100.0, :d) }
    steps = xs.each_cons(2).map { |a, b| (b - a).abs }
    expect(steps.max).to be < 0.05
    expect(xs.min).to be >= 0
    expect(xs.max).to be <= 1
  end

  it 'shuffles repeatably' do
    a = dice.shuffle(1..10, :s)
    expect(a.sort).to eq((1..10).to_a)
    expect(dice.shuffle(1..10, :s)).to eq(a)
    expect(dice.shuffle(1..10, :t)).not_to eq(a)
  end

  it 'is a console method that draws its seed from the root seed' do
    MB::Sound.seed(5)
    a = MB::Sound.dice
    MB::Sound.seed(5)
    expect(MB::Sound.dice).to eq(a)
    expect(MB::Sound.dice(3, :x)).to eq(dice[:x])
  end
end
