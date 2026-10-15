require 'shellwords'

RSpec.describe('MB::Sound::FastTexture', :aggregate_failures) do
  let(:fast) { MB::Sound::FastTexture }
  let(:dust) { MB::Sound::GraphNode::Dust }
  let(:drift) { MB::Sound::GraphNode::Drift }
  let(:rng) { Random.new(5) }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_texture.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastTexture.respond_to?(:drift)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  def rates(n, scale, offset = 0)
    Numo::SFloat.cast(Array.new(n) { rng.rand * scale + offset })
  end

  def compare_dust(n, rate, lo: 0.0, hi: 1.0, seed: 777, gap: 0)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    ra = Numo::UInt64[seed]
    rb = Numo::UInt64[seed]
    ga = Numo::DFloat[Float::INFINITY]
    gb = Numo::DFloat[Float::INFINITY]
    fast.dust(a, rate, ra, 48000, lo, hi, gap, ga)
    dust.process_ruby(b, rate, rb, 48000, lo, hi, gap, gb)
    expect(a).to eq(b)
    expect(ra).to eq(rb)
    expect(ga).to eq(gb)
    a
  end

  STATE = [0.0, 0.1, 0.6, 0.9, 0.2, Float::NAN, Float::NAN].freeze

  # Runs the kernel and the mirror on the same arguments; options:
  # table:, hold: [lo, hi, kind], jitter:.
  def compare_drift(n, rate, mode, walk, state: STATE, seed: 31, table: nil, hold: [nil, nil, 0], jitter: nil)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    sa = Numo::DFloat.cast(state)
    sb = Numo::DFloat.cast(state)
    ra = Numo::UInt64[seed, seed + 1, seed + 2]
    rb = Numo::UInt64[seed, seed + 1, seed + 2]
    fast.drift(a, rate, sa, ra, 48000, -2.0, 3.0, mode, walk, table, *hold, jitter)
    drift.process_ruby(b, rate, sb, rb, 48000, -2.0, 3.0, mode, walk, table, *hold, jitter)
    expect(a).to eq(b), "mode #{mode} walk #{walk} rate #{rate.class} hold #{hold} jitter #{jitter.class}"
    expect(sa.to_a.map { |v| v.nan? ? :nan : v }).to eq(sb.to_a.map { |v| v.nan? ? :nan : v })
    expect(ra).to eq(rb)
    a
  end

  # Distinct values in order (the points a step drift visits).
  def visits(out)
    out.to_a.chunk_while { |x, y| x == y }.map(&:first)
  end

  describe '.dust' do
    it 'matches the Ruby mirror for fixed, moving, and edge-case rates' do
      compare_dust(4000, 300.0)
      compare_dust(4000, rates(4000, 4000), lo: -1.0, hi: 1.0)
      compare_dust(4000, Numo::DFloat.cast(rates(4000, 100)), lo: 0.5, hi: 0.5, seed: 2**64 - 1)
      edge = Numo::SFloat.cast([0, -5, Float::NAN, Float::INFINITY, 48000, 96000, 1e-30] * 30)
      compare_dust(edge.length, edge)
    end

    it 'makes about rate impulses per second with heights spread over the range' do
      out = compare_dust(480000, 200.0, lo: 0.25, hi: 0.75)
      hits = out[out.ne(0)]
      expect(hits.length).to be_within(150).of(2000)
      expect(hits.min).to be >= 0.25
      expect(hits.max).to be <= 0.75
      expect(hits.mean).to be_within(0.02).of(0.5)
    end

    it 'gives the same samples at any block size' do
      rate = rates(3000, 3000)
      whole = compare_dust(3000, rate).dup
      r = Numo::UInt64[777]
      g = Numo::DFloat[Float::INFINITY]
      pieces = []
      pos = 0
      [1, 7, 128, 800, 13, 2051].each do |len|
        out = Numo::SFloat.zeros(len)
        fast.dust(out, rate[pos...(pos + len)].dup, r, 48000, 0.0, 1.0, 0, g)
        pieces.concat(out.to_a)
        pos += len
      end
      expect(pieces).to eq(whole.to_a)
    end

    it 'raises for bad arguments' do
      out = Numo::SFloat.zeros(4)
      r = Numo::UInt64[1]
      g = Numo::DFloat[0]
      expect { fast.dust(out, 10.0, r, 0, 0, 1, 0, g) }.to raise_error(ArgumentError, /sample rate/)
      expect { fast.dust(out, 10.0, Numo::Int64[1], 48000, 0, 1, 0, g) }.to raise_error(ArgumentError, /random/)
      expect { fast.dust(Numo::DFloat.zeros(4), 10.0, r, 48000, 0, 1, 0, g) }.to raise_error(ArgumentError, /output/)
      expect { fast.dust(out, Numo::SFloat.zeros(3), r, 48000, 0, 1, 0, g) }.to raise_error(ArgumentError, /length/)
      expect { fast.dust(out, 10.0, r, 48000, 0, 1, Numo::SFloat.zeros(3), g) }.to raise_error(ArgumentError, /length/)
      expect { fast.dust(out, 10.0, r, 48000, 0, 1, 0, Numo::DFloat.zeros(2)) }.to raise_error(ArgumentError, /gap state/)
      expect { fast.dust(out.freeze, 10.0, r, 48000, 0, 1, 0, g) }.to raise_error(FrozenError)
      expect { fast.dust(Numo::SFloat.zeros(4), 10.0, r, 48000, 0, 1, 0, g.dup.freeze) }.to raise_error(FrozenError)
    end

    context 'with a minimum gap' do
      it 'matches the Ruby mirror for fixed, moving, and edge-case gaps' do
        compare_dust(20000, 300.0, gap: 480.0)
        compare_dust(20000, 300.0, gap: 160.5)
        compare_dust(20000, rates(20000, 2000), gap: rates(20000, 900))
        edge = Numo::SFloat.cast([0, -5, Float::NAN, Float::INFINITY, 1, 1.5, 48000, 1e-30] * 30)
        compare_dust(edge.length, 4000.0, gap: edge)
        compare_dust(edge.length, edge, gap: 3.0)
      end

      it 'keeps impulses at least the gap apart, at the same average rate' do
        out = compare_dust(48000 * 20, 20.0, gap: 960.0) # 20 ms apart at the least, 20 per second
        hits = out.ne(0).where.to_a
        expect(hits.each_cons(2).map { |a, b| b - a }.min).to be >= 960
        expect(hits.length).to be_within(40).of(400)
      end

      it 'strikes like clockwork once the rate reaches one per gap' do
        out = compare_dust(48000, 1000.0, gap: 480.0)
        hits = out.ne(0).where.to_a
        expect(hits.each_cons(2).map { |a, b| b - a }.uniq).to eq([480])
      end

      it 'is the same as no gap for gaps of one sample or less' do
        expect(compare_dust(4000, 3000.0, gap: 1.0)).to eq(compare_dust(4000, 3000.0))
        expect(compare_dust(4000, 3000.0, gap: 0.0)).to eq(compare_dust(4000, 3000.0))
      end
    end
  end

  describe '.drift' do
    let(:back) { MB::Sound::Curve[:back, overshoot: 0.4].value_table.to_a }
    let(:steps) { MB::Sound::Curve.steps(3).value_table.to_a }

    it 'matches the Ruby mirror in every mode, with and without a walk' do
      moving = rates(3000, 200)
      (0..3).each do |mode|
        [0.0, 0.25, 1.0].each do |walk|
          compare_drift(3000, 40.0, mode, walk)
          compare_drift(3000, moving, mode, walk)
        end
      end
      edge = Numo::SFloat.cast([0, -5, Float::NAN, Float::INFINITY, 48000, 24000, 1e-30] * 30)
      compare_drift(edge.length, edge, 3, 0.5)
      compare_drift(edge.length, edge, 4, 0.5, table: back, hold: [0.2, 0.9, 0], jitter: 1.0)
    end

    it 'matches the Ruby mirror with curves, holds, and jitter' do
      moving = rates(3000, 200)
      [back, steps].each do |table|
        compare_drift(3000, 40.0, 4, 0.0, table: table)
        compare_drift(3000, moving, 4, 0.3, table: table)
      end
      (0..4).each do |mode|
        t = mode == 4 ? back : nil
        compare_drift(3000, 40.0, mode, 0.2, table: t, hold: [0.5, 0.5, 0])
        compare_drift(3000, moving, mode, 0.2, table: t, hold: [0.1, 0.9, 0], jitter: 0.5)
        compare_drift(3000, 40.0, mode, 0.0, table: t, hold: [100.0, 1500.0, 1], jitter: rates(3000, 1))
        compare_drift(3000, 40.0, mode, 0.0, table: t, hold: [rates(3000, 1), rates(3000, 1, 0.5), 0], jitter: 1.0)
      end
      edge = Numo::SFloat.cast([0, -5, Float::NAN, Float::INFINITY, 1, 2, 1e-30] * 30)
      compare_drift(edge.length, 4000.0, 1, 0.0, hold: [edge, edge, 0], jitter: edge)
      compare_drift(edge.length, 4000.0, 1, 0.0, hold: [edge, edge, 1])
    end

    it 'follows the curve between points, overshooting with :back' do
      lin = compare_drift(4800, 100.0, 1, 0.0)
      curve = compare_drift(4800, 100.0, 4, 0.0, table: back)
      (0...10).each { |k| expect(curve[k * 480]).to eq(lin[k * 480]) }
      expect(curve.max).to be > lin.max
    end

    it 'holds each point for the hold before moving on' do
      out = compare_drift(4800, 100.0, 1, 0.0, hold: [0.25, 0.25, 0]) # 480-sample steps, 120 held
      (0...10).each do |k|
        expect(out[(k * 480)...(k * 480 + 120)].to_a.uniq.length).to eq(1)
        expect(out[k * 480 + 121]).not_to eq(out[k * 480 + 120])
      end
      timed = compare_drift(4800, 100.0, 1, 0.0, hold: [120.0, 120.0, 1])
      expect(timed).to eq(out)
    end

    it 'visits the same points whatever the hold and spacing' do
      plain = visits(compare_drift(48000, 100.0, 0, 0.3))
      held = visits(compare_drift(48000, 100.0, 0, 0.3, hold: [0.1, 0.9, 0]))
      jittered = visits(compare_drift(96000, 100.0, 0, 0.3, jitter: 1.0))
      expect(held).to eq(plain)
      n = [plain.length, jittered.length].min
      expect(jittered.first(n)).to eq(plain.first(n))
    end

    it 'spaces points unevenly with jitter, keeping the average rate' do
      even = compare_drift(48000 * 10, 50.0, 0, 0.0)
      [0.5, 1.0].each do |j|
        out = compare_drift(48000 * 10, 50.0, 0, 0.0, jitter: j)
        edges = (1...out.length).select { |i| out[i] != out[i - 1] }
        gaps = edges.each_cons(2).map { |a, b| b - a }
        expect(edges.length).to be_within(60).of(500)
        expect(gaps.min).to be < 960 * (j == 1.0 ? 0.2 : 0.6)
        expect(gaps.max).to be > 960 * 2
      end
      expect((1...even.length).count { |i| even[i] != even[i - 1] }).to eq(499) # (the 500th lands just past the end)
    end

    it 'gives the same samples at any block size with curves, holds, and jitter' do
      rate = rates(6000, 400)
      jit = rates(6000, 1)
      whole = compare_drift(6000, rate, 4, 0.4, table: back, hold: [0.1, 0.8, 0], jitter: jit).dup
      st = Numo::DFloat.cast(STATE)
      r = Numo::UInt64[31, 32, 33]
      pieces = []
      pos = 0
      [1, 7, 128, 800, 13, 2051, 3000].each do |len|
        len = [len, 6000 - pos].min
        break if len <= 0
        out = Numo::SFloat.zeros(len)
        fast.drift(out, rate[pos...(pos + len)].dup, st, r, 48000, -2.0, 3.0, 4, 0.4, back, 0.1, 0.8, 0, jit[pos...(pos + len)].dup)
        pieces.concat(out.to_a)
        pos += len
      end
      expect(pieces).to eq(whole.to_a)
    end

    it 'steps exactly at rates dividing the sample rate' do
      out = compare_drift(48000 * 3, 1.0, 0, 0.0)
      changes = (1...out.length).select { |i| out[i] != out[i - 1] }
      expect(changes).to eq([48000, 96000])
    end

    it 'joins the points: linear and cosine pass through them, cubic stays inside the range' do
      lin = compare_drift(4800, 100.0, 1, 0.0)
      cos = compare_drift(4800, 100.0, 2, 0.0)
      step = compare_drift(4800, 100.0, 0, 0.0)
      (0...10).each do |k|
        expect(lin[k * 480]).to eq(step[k * 480])
        expect(cos[k * 480]).to eq(step[k * 480])
      end
      cubic = compare_drift(48000, 300.0, 3, 0.0, state: [0.0, 0.0, 1.0, 0.0, 1.0, Float::NAN, Float::NAN])
      expect(cubic.min).to be >= -2.0
      expect(cubic.max).to be <= 3.0
    end

    it 'keeps walk steps within the walk' do
      out = compare_drift(48000, 4800.0, 0, 0.1, state: [0.0, 0.5, 0.5, 0.5, 0.5, Float::NAN, Float::NAN])
      steps = (out[10..] - out[0...-10]).abs # one point per 10 samples, in a range 5 wide
      expect(steps.max).to be <= 0.5 + 1e-5
    end

    it 'raises for bad arguments' do
      out = Numo::SFloat.zeros(4)
      st = Numo::DFloat.zeros(7)
      r = Numo::UInt64[1, 2, 3]
      rest = [nil, nil, nil, 0, nil]
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 5, 0, *rest) }.to raise_error(ArgumentError, /mode/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 4, 0, *rest) }.to raise_error(ArgumentError, /curve table/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 4, 0, [Numo::DFloat[1]] * 4, nil, nil, 0, nil) }.to raise_error(ArgumentError, /at least two/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 4, 0, [Numo::DFloat[0, 1], Numo::DFloat[0, 1], Numo::DFloat[1], Numo::DFloat[1, 1]], nil, nil, 0, nil) }.to raise_error(ArgumentError, /left slopes/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 0, 1.5, *rest) }.to raise_error(ArgumentError, /walk/)
      expect { fast.drift(out, 1.0, Numo::DFloat.zeros(5), r, 48000, 0, 1, 0, 0, *rest) }.to raise_error(ArgumentError, /state/)
      expect { fast.drift(out, 1.0, st, Numo::UInt64[1], 48000, 0, 1, 0, 0, *rest) }.to raise_error(ArgumentError, /random/)
      expect { fast.drift(out, 1.0, st, r, -1, 0, 1, 0, 0, *rest) }.to raise_error(ArgumentError, /sample rate/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 0, 0, nil, Numo::SFloat.zeros(3), 0.5, 0, nil) }.to raise_error(ArgumentError, /length/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 0, 0, nil, nil, nil, 0, Numo::SFloat.zeros(3)) }.to raise_error(ArgumentError, /length/)
      expect { fast.drift(out, 1.0, st.freeze, r, 48000, 0, 1, 0, 0, *rest) }.to raise_error(FrozenError)
    end
  end
end
