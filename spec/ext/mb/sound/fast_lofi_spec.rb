require 'shellwords'

RSpec.describe('MB::Sound::FastLofi', :aggregate_failures) do
  let(:fast) { MB::Sound::FastLofi }
  let(:mirror) { MB::Sound::GraphNode::Decimator }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_lofi.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastLofi.respond_to?(:decimate)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  # Runs the kernel and the mirror from the same state and expects identical
  # samples and states.
  def compare(n, input, rate, jitter: 0.0, state: [1.0, 0.0, 1.0, 0.0], seed: 12345, sample_rate: 48000, mode: 0)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    sa = Numo::DFloat.cast(state)
    sb = Numo::DFloat.cast(state)
    ra = Numo::UInt64[seed]
    rb = Numo::UInt64[seed]
    fast.decimate(a, input, rate, sa, ra, sample_rate, jitter, mode)
    mirror.process_ruby(b, input, rate, sb, rb, sample_rate, jitter, mode)
    expect(a).to eq(b), "n=#{n} rate=#{rate.class} jitter=#{jitter} mode=#{mode}"
    expect(sa).to eq(sb)
    expect(ra).to eq(rb)
    a
  end

  let(:rng) { Random.new(5) }

  def noise(n, scale = 1.0)
    Numo::SFloat.cast(Array.new(n) { (rng.rand - 0.5) * scale })
  end

  it 'matches the Ruby mirror with scalar and array rates' do
    x = noise(1000)
    compare(1000, x, 3000.0)
    compare(1000, x, 4321.7)
    compare(1000, x, noise(1000, 20000) + 10000)
    compare(1000, Numo::DFloat.cast(x), Numo::DFloat.cast(noise(1000, 2000) + 5000))
    compare(1000, 0.3, 1000.0)
  end

  it 'matches the Ruby mirror with jitter' do
    x = noise(2000)
    compare(2000, x, 2500.0, jitter: 0.5)
    compare(2000, x, noise(2000, 3000) + 4000, jitter: 0.95, seed: 2**64 - 3)
  end

  it 'matches the Ruby mirror for edge-case rates' do
    rates = Numo::SFloat.cast([0, -100, Float::NAN, Float::INFINITY, 48000, 96000, 1e-30, 24000] * 50)
    compare(rates.length, noise(rates.length), rates)
    compare(100, noise(100), Float::INFINITY)
    compare(100, noise(100), -5.0)
  end

  it 'holds each input sample until the next tick' do
    x = Numo::SFloat.new(12).seq
    expect(compare(12, x, 12000.0).to_a).to eq([0, 0, 0, 0, 4, 4, 4, 4, 8, 8, 8, 8])
    expect(compare(12, x, 48000.0).to_a).to eq(x.to_a)
    expect(compare(12, x, 0.0).to_a).to eq([0] * 12) # first sample held
  end

  it 'gives the same samples at any block size, holding or linear' do
    x = noise(3000)
    rate = noise(3000, 4000) + 3000
    [0, 1].each do |mode|
      whole = compare(3000, x, rate, jitter: 0.3, mode: mode).dup

      st = Numo::DFloat[1.0, 0.0, 1.0, 0.0]
      r = Numo::UInt64[12345]
      pieces = []
      pos = 0
      [1, 7, 128, 800, 13, 2051].each do |len|
        out = Numo::SFloat.zeros(len)
        fast.decimate(out, x[pos...(pos + len)].dup, rate[pos...(pos + len)].dup, st, r, 48000, 0.3, mode)
        pieces.concat(out.to_a)
        pos += len
      end
      expect(pieces).to eq(whole.to_a)
    end
  end

  describe 'linear interpolation (mode 1)' do
    it 'matches the Ruby mirror with fixed, moving, edge-case, and jittered rates' do
      x = noise(2000)
      compare(2000, x, 3000.0, mode: 1)
      compare(2000, x, 4321.7, mode: 1)
      compare(2000, x, noise(2000, 20000) + 10000, mode: 1)
      compare(2000, x, 2500.0, jitter: 0.8, mode: 1)
      rates = Numo::SFloat.cast([0, -100, Float::NAN, Float::INFINITY, 48000, 96000, 1e-30, 24000] * 50)
      compare(rates.length, noise(rates.length), rates, mode: 1)
    end

    it 'draws lines between the held samples, one hold period late' do
      x = Numo::SFloat.new(16).seq
      expect(compare(16, x, 12000.0, mode: 1).to_a).to eq([0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
      expect(compare(12, x[0...12], 48000.0, mode: 1).to_a).to eq([0] + (0..10).to_a) # one sample late at full rate
    end

    it 'folds the same, with much weaker images far above the rate' do
      # A 1 kHz sine crushed at 7 kHz: images at 6, 8, 13, 15 kHz ...
      t = Numo::SFloat.new(48000).seq / 48000.0
      x = Numo::NMath.sin(t * 2 * Math::PI * 1000)
      band = ->(y, lo, hi) {
        s = MB::Sound.real_fft(Numo::DFloat.cast(y)).abs**2
        f = Numo::DFloat.new(s.length).seq * (48000.0 / y.length)
        10 * Math.log10(s[(f >= lo) & (f <= hi)].sum)
      }
      hold = compare(48000, x, 7000.0)
      lin = compare(48000, x, 7000.0, mode: 1)
      main_hold = band.(hold, 990, 1010)
      main_lin = band.(lin, 990, 1010)
      # the near image (6 kHz) still there: grunge
      expect(band.(lin, 5990, 6010) - main_lin).to be > -40
      # far images (above 12 kHz) at least 12 dB weaker relative to the tone
      expect((band.(lin, 12000, 24000) - main_lin) - (band.(hold, 12000, 24000) - main_hold)).to be < -12
    end
  end

  it 'raises for bad arguments' do
    out = Numo::SFloat.zeros(4)
    st = Numo::DFloat[1, 0, 1, 0]
    r = Numo::UInt64[1]
    expect { fast.decimate(out, 0.0, 1000.0, st, r, 48000, 1.0, 0) }.to raise_error(ArgumentError, /jitter/)
    expect { fast.decimate(out, 0.0, 1000.0, st, r, 0, 0, 0) }.to raise_error(ArgumentError, /sample rate/)
    expect { fast.decimate(out, 0.0, 1000.0, Numo::DFloat[1, 0, 1], r, 48000, 0, 0) }.to raise_error(ArgumentError, /state/)
    expect { fast.decimate(out, 0.0, 1000.0, st, Numo::Int64[1], 48000, 0, 0) }.to raise_error(ArgumentError, /random/)
    expect { fast.decimate(Numo::DFloat.zeros(4), 0.0, 1000.0, st, r, 48000, 0, 0) }.to raise_error(ArgumentError, /output/)
    expect { fast.decimate(out, Numo::SFloat.zeros(3), 1000.0, st, r, 48000, 0, 0) }.to raise_error(ArgumentError, /length/)
    expect { fast.decimate(out, 0.0, 1000.0, st, r, 48000, 0, 2) }.to raise_error(ArgumentError, /mode/)
    expect { fast.decimate(out.freeze, 0.0, 1000.0, st, r, 48000, 0, 0) }.to raise_error(FrozenError)
  end
end
