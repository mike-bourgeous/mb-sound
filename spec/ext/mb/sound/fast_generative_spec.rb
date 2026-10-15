require 'shellwords'

RSpec.describe('MB::Sound::FastGenerative', :aggregate_failures) do
  let(:fast) { MB::Sound::FastGenerative }
  let(:dice) { MB::Sound::Generative::Dice }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_generative.so', __dir__)
    code = 'GC.stress = true; require ARGV[0]; s = MB::Sound::FastGenerative.start(3); x = MB::Sound::FastGenerative.rand(s, :a, 2**70, 3r/4, "b"); GC.stress = false; p x.between?(0, 1)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  # Every kind of key, including the edges of 64-bit and fixnum ranges.
  KEYS = [
    0, 1, -1, 37, 2**62 - 1, 2**62, -(2**62), -(2**62) - 1, 2**63 - 1, 2**63, 2**64 - 1, 2**64, 2**70 + 5, -(2**70) - 3,
    :kick, :"", :hat, 'kick', '', 'ü€😀', 3r/4, -5r/3, Rational(2**65, 3), nil,
  ].freeze

  it 'hashes keys like the Ruby mirror' do
    KEYS.each do |k|
      expect(fast.key(k)).to eq(dice.key_ruby(k)), k.inspect
    end
    expect(fast.key(:kick)).to eq(fast.key('kick'))
    expect(fast.key(-1)).to eq(2**64 - 1)
    expect(fast.key(2**64 + 7)).to eq(7)
  end

  it 'folds, draws, and draws in rows like the Ruby mirror' do
    [0, 1, -1, 12345, 2**63 + 1, 2**80].each do |seed|
      s = fast.start(seed)
      expect(s).to eq(dice.start_ruby(seed))
      expect(s).to be_between(0, 2**64 - 1)

      KEYS.each_cons(3) do |keys|
        expect(fast.fold(s, *keys)).to eq(dice.fold_ruby(s, *keys)), keys.inspect
        expect(fast.rand(s, *keys)).to eq(dice.unit_ruby(s, *keys)), keys.inspect
      end
      expect(fast.fold(s)).to eq(s)
      expect(fast.rands(s, 50)).to eq(dice.units_ruby(s, 50))
      expect(fast.rands(s, 0)).to eq([])
    end
  end

  it 'folds keys one at a time the same as all at once' do
    s = fast.start(7)
    expect(fast.fold(fast.fold(s, :a), 3, :b)).to eq(fast.fold(s, :a, 3, :b))
    expect(fast.rand(fast.fold(s, :a), 3)).to eq(fast.rand(s, :a, 3))
    expect(fast.rands(fast.fold(s, :row), 4)[2]).to eq(fast.rand(s, :row, 2))
  end

  it 'gives uniform Floats in 0...1' do
    s = fast.start(1)
    u = fast.rands(s, 20_000)
    expect(u.min).to be >= 0
    expect(u.max).to be < 1
    expect(u.sum / u.length).to be_within(0.01).of(0.5)
    hist = u.group_by { |x| (x * 10).floor }.transform_values(&:length)
    expect(hist.values).to all(be_within(150).of(2000))
  end

  it 'picks like the Ruby mirror, with Array#sum totals' do
    r = Random.new(5)
    500.times do
      w = Array.new(r.rand(1..40)) { r.rand < 0.2 ? 0.0 : r.rand * 10**r.rand(-8..8) }
      10.times do
        u = r.rand
        expect(fast.pick(w, u)).to eq(dice.pick_ruby(w, u)), [w, u].inspect
      end
      expect(fast.pick(w, 0.0)).to eq(dice.pick_ruby(w, 0.0))
      expect(fast.pick(w, 1.0 - 2**-53)).to eq(dice.pick_ruby(w, 1.0 - 2**-53))
    end
  end

  it 'totals badly conditioned weights like Array#sum' do
    # Kahan-Babuska compensation changes the total here; a plain sum would
    # pick differently near the end
    w = [1e16, 1.0, 1.0, 1e-3, 3.0]
    expect(w.sum).not_to eq(w.reduce(:+))
    (0..1000).each do |i|
      u = 1.0 - i * 1e-17
      expect(fast.pick(w, u)).to eq(dice.pick_ruby(w, u))
    end
    expect(fast.pick([Float::NAN, 1.0], 0.5)).to eq(-1)
  end

  it 'returns -1 when nothing can be picked' do
    expect(fast.pick([], 0.5)).to eq(-1)
    expect(fast.pick([0.0, 0.0], 0.5)).to eq(-1)
    expect(fast.pick([1.0, -2.0], 0.5)).to eq(-1)
    expect(fast.pick([Float::INFINITY, 1.0], 0.5)).to eq(-1)
    expect(fast.pick([0.0, 2.0, 0.0], 0.0)).to eq(1)
  end

  it 'rejects keys and states that would make draws depend on rounding or identity' do
    s = fast.start(1)
    expect { fast.key(0.5) }.to raise_error(ArgumentError, /Dice keys/)
    expect { fast.rand(s, :a, Object.new) }.to raise_error(ArgumentError, /Dice keys/)
    expect { fast.rand(0.5) }.to raise_error(TypeError, /state/)
    expect { fast.start(1.5) }.to raise_error(TypeError, /seed/)
    expect { fast.rands(s, -1) }.to raise_error(ArgumentError, /negative/)
    expect { fast.pick(:x, 0.5) }.to raise_error(TypeError)
    expect { fast.fold }.to raise_error(ArgumentError)
  end
end
