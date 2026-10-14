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

  def compare_dust(n, rate, lo: 0.0, hi: 1.0, seed: 777)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    ra = Numo::UInt64[seed]
    rb = Numo::UInt64[seed]
    fast.dust(a, rate, ra, 48000, lo, hi)
    dust.process_ruby(b, rate, rb, 48000, lo, hi)
    expect(a).to eq(b)
    expect(ra).to eq(rb)
    a
  end

  def compare_drift(n, rate, mode, walk, state: [0.0, 0.1, 0.6, 0.9, 0.2], seed: 31)
    a = Numo::SFloat.zeros(n)
    b = Numo::SFloat.zeros(n)
    sa = Numo::DFloat.cast(state)
    sb = Numo::DFloat.cast(state)
    ra = Numo::UInt64[seed]
    rb = Numo::UInt64[seed]
    fast.drift(a, rate, sa, ra, 48000, -2.0, 3.0, mode, walk)
    drift.process_ruby(b, rate, sb, rb, 48000, -2.0, 3.0, mode, walk)
    expect(a).to eq(b), "mode #{mode} walk #{walk} rate #{rate.class}"
    expect(sa).to eq(sb)
    expect(ra).to eq(rb)
    a
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
      pieces = []
      pos = 0
      [1, 7, 128, 800, 13, 2051].each do |len|
        out = Numo::SFloat.zeros(len)
        fast.dust(out, rate[pos...(pos + len)].dup, r, 48000, 0.0, 1.0)
        pieces.concat(out.to_a)
        pos += len
      end
      expect(pieces).to eq(whole.to_a)
    end

    it 'raises for bad arguments' do
      out = Numo::SFloat.zeros(4)
      r = Numo::UInt64[1]
      expect { fast.dust(out, 10.0, r, 0, 0, 1) }.to raise_error(ArgumentError, /sample rate/)
      expect { fast.dust(out, 10.0, Numo::Int64[1], 48000, 0, 1) }.to raise_error(ArgumentError, /random/)
      expect { fast.dust(Numo::DFloat.zeros(4), 10.0, r, 48000, 0, 1) }.to raise_error(ArgumentError, /output/)
      expect { fast.dust(out, Numo::SFloat.zeros(3), r, 48000, 0, 1) }.to raise_error(ArgumentError, /length/)
      expect { fast.dust(out.freeze, 10.0, r, 48000, 0, 1) }.to raise_error(FrozenError)
    end
  end

  describe '.drift' do
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
      cubic = compare_drift(48000, 300.0, 3, 0.0, state: [0.0, 0.0, 1.0, 0.0, 1.0])
      expect(cubic.min).to be >= -2.0
      expect(cubic.max).to be <= 3.0
    end

    it 'keeps walk steps within the walk' do
      out = compare_drift(48000, 4800.0, 0, 0.1, state: [0.0, 0.5, 0.5, 0.5, 0.5])
      steps = (out[10..] - out[0...-10]).abs # one point per 10 samples, in a range 5 wide
      expect(steps.max).to be <= 0.5 + 1e-5
    end

    it 'raises for bad arguments' do
      out = Numo::SFloat.zeros(4)
      st = Numo::DFloat.zeros(5)
      r = Numo::UInt64[1]
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 4, 0) }.to raise_error(ArgumentError, /mode/)
      expect { fast.drift(out, 1.0, st, r, 48000, 0, 1, 0, 1.5) }.to raise_error(ArgumentError, /walk/)
      expect { fast.drift(out, 1.0, Numo::DFloat.zeros(4), r, 48000, 0, 1, 0, 0) }.to raise_error(ArgumentError, /state/)
      expect { fast.drift(out, 1.0, st, r, -1, 0, 1, 0, 0) }.to raise_error(ArgumentError, /sample rate/)
      expect { fast.drift(out, 1.0, st.freeze, r, 48000, 0, 1, 0, 0) }.to raise_error(FrozenError)
    end
  end
end
