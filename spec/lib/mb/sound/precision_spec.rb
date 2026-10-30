# fast-sine-1: MB::Sound.precision applies to planned and unplanned graphs
# together; at :fast the unfused C kernels, their Ruby mirrors, and plans
# compute the same samples.
RSpec.describe(MB::Sound::Precision) do
  around do |ex|
    old = MB::Sound.precision
    ex.run
  ensure
    MB::Sound.precision = old
  end

  it 'is :fast by default, sets the C kernels, and is the setting Plan.precision reads' do
    expect(MB::Sound.precision).to eq(:fast)
    expect(MB::FastSound.fast_math?).to eq(true)
    MB::Sound.precision = :exact
    expect(MB::FastSound.fast_math?).to eq(false)
    expect(MB::Sound::Plan.precision).to eq(:exact)
    MB::Sound::Plan.precision = :fast
    expect(MB::Sound.precision).to eq(:fast)
    expect { MB::Sound.precision = :double }.to raise_error(ArgumentError, /:fast or :exact/)
  end

  [:fast, :exact].each do |prec|
    it "gives unfused naive sines the same samples in C and Ruby at #{prec}" do
      MB::Sound.precision = prec
      make = -> { 220.hz.fm(330.hz.at(500)).pm(3.hz.lfo.at(0.2)).at(0.7) }
      c = make.call
      r = make.call
      bufs = [800, 7, 128].map { |n| [c.sample(n).dup, sample_with(:ruby, r, n).dup] }
      bufs.each { |x, y| expect(x.to_binary).to eq(Numo::SFloat.cast(y).to_binary) }
    end
  end

  it 'uses the fast sine unfused at :fast and libm at :exact' do
    make = -> { 220.hz.fm(330.hz.at(500)) }
    MB::Sound.precision = :fast
    fast = make.call.sample(4800).dup
    MB::Sound.precision = :exact
    exact = make.call.sample(4800).dup
    d = (fast - exact).abs.max
    expect(d).to be > 0
    expect(d).to be < 1e-5
  end

  it 'gives FastSound.number_to_freq the mirror\'s 2^x at :fast' do
    n = Numo::SFloat.new(1000).seq(0, 0.127) # (crosses chunks of 256)
    n[3] = 69 + 12 * 250 # beyond the polynomial's limit
    got = MB::FastSound.number_to_freq(n.dup.inplace!, 69, 440).not_inplace!
    expect(got.to_binary).to eq(MB::Sound::Plan::VecExp2.note_freq(n, 69, 440).to_binary)
  end

  it 'raises Constant bases with FastArithmetic.power_fast, as the mirror does' do
    a = Numo::SFloat.new(600).fill(10)
    b = Numo::SFloat.new(600).rand(-3, 3)
    expect(MB::Sound::FastArithmetic.power_fast(a.dup, b).to_binary).to eq(MB::Sound::Plan::VecExp2.pow(a, b).to_binary)
    filled = Numo::SFloat.new(600).fill(1.5)
    expect(MB::Sound::FastArithmetic.power_fast(a.dup, 1.5).to_binary).to eq(MB::Sound::Plan::VecExp2.pow(a, filled).to_binary)
    expect(MB::Sound::FastArithmetic.power_fast(Numo::DFloat.new(4).fill(2), 2.0)).to be_nil

    g = 10 ** (3.hz.lfo / 20)
    expect(g.fast_power_base).to eq(true)
    expect((3.hz.lfo ** 2.0).fast_power_base).to eq(false)
  end
end
