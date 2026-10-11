require 'shellwords'

RSpec.describe('MB::Sound::FastDynamics', :aggregate_failures) do
  let(:fast) { MB::Sound::FastDynamics }
  let(:dyn) { MB::Sound::GraphNode::Dynamics }
  let(:rng) { Random.new(7) }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_dynamics.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastDynamics.respond_to?(:compand)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  # Noise with bursts: loud and quiet stretches so every branch of the
  # smoother runs.
  def bursty(n, level: 1.0)
    Numo::SFloat.cast(Array.new(n) { |i| (rng.rand - 0.5) * 2 * level * ((i / 37).even? ? 1 : 0.01) })
  end

  describe '.compand' do
    let(:curve) {
      dyn::Transfer.corners(-40, [[-40, 2.0, 1.0], [-20, 1.0, 0.25]], knee: 6).table
    }

    def params(mode: 0, min: -60.0, max: 12.0, makeup: 1.5, hold_up: 1, link: 1, la: 0, mix: 1.0)
      Numo::DFloat[mode, min, max, makeup, hold_up, link, la, mix]
    end

    # Runs kernel and mirror in several blocks from the same state, expecting
    # identical samples, states, and delay lines.
    def compare(nch, n, ins:, sides: nil, prm: params, times: [480.0, 24.0, 2400.0, 5.0, 0.0], ndet: 1, blocks: [n], crv: curve)
      la = prm[6].to_i
      sa = Numo::DFloat.zeros(ndet * 3 + 1)
      sb = sa.dup
      da = la > 0 ? Numo::DFloat.zeros(nch * la) : nil
      db = da&.dup
      out = []
      off = 0
      blocks.each do |len|
        cut = ->(v) { v.is_a?(Numo::NArray) ? v[off...(off + len)] : v }
        a = Array.new(nch) { Numo::SFloat.zeros(len) }
        b = Array.new(nch) { Numo::SFloat.zeros(len) }
        i = ins.map(&cut)
        s = (sides || ins).map(&cut)
        t = times.map(&cut)
        fast.compand(a, i, s, crv, prm, t, sa, da)
        dyn.process_ruby(b, i, s, crv, prm, t, sb, db)
        expect(a).to eq(b)
        expect(sa).to eq(sb)
        expect(da).to eq(db)
        out << a.map(&:dup)
        off += len
      end
      out
    end

    it 'matches the Ruby mirror for a linked peak detector' do
      x = bursty(1000)
      out = compare(1, 1000, ins: [x], blocks: [1, 7, 128, 864])
      expect(out.map { |o| o[0].abs.max }.max).to be > 0.1
    end

    it 'matches the Ruby mirror for an RMS detector, unlinked stereo, and lookahead' do
      l = bursty(600)
      r = bursty(600, level: 0.3)
      compare(2, 600, ins: [l, r], prm: params(mode: 1, link: 0, la: 17, mix: 0.3), ndet: 2, blocks: [100, 500])
    end

    it 'matches the Ruby mirror with a sidechain, holds in both directions, and per-sample times' do
      x = bursty(700)
      kick = bursty(700)
      times = [240.0, Numo::SFloat.linspace(0, 200, 700), Numo::SFloat.linspace(4000, 10, 700), Numo::SFloat.linspace(0, 30, 700), 50.0]
      compare(1, 700, ins: [x], sides: [kick, x], prm: params(hold_up: 1), times: times, blocks: [333, 367])
      compare(1, 700, ins: [x], sides: [kick], prm: params(hold_up: 0, min: -80.0, max: 0.0), times: times)
    end

    it 'matches the Ruby mirror with upward boosts falling at their own speed' do
      up = dyn::Transfer.corners(-40, [[-40, 0.5, 1.0], [-20, 1.0, 0.25]], knee: 6).table
      x = bursty(900)
      out = compare(1, 900, ins: [x], crv: up, prm: params(max: 24.0), times: [480.0, 240.0, 480.0, 3.0, 0.0], blocks: [450, 450])
      expect(out.map { |o| (o[0] / x[0...450].abs.max).abs.max }.max).to be > 0
    end

    it 'treats nil inputs and sidechains as silence' do
      compare(2, 64, ins: [nil, bursty(64)], sides: [nil], prm: params(la: 3))
    end

    it 'rejects bad arguments' do
      out = [Numo::SFloat.zeros(4)]
      st = Numo::DFloat.zeros(4)
      t = [0, 0, 0, 0, 0]
      expect { fast.compand(out, [nil, nil], [nil], curve, params, t, st, nil) }.to raise_error(ArgumentError, /inputs/)
      expect { fast.compand(out, [nil], [], curve, params, t, st, nil) }.to raise_error(ArgumentError, /sidechain/)
      expect { fast.compand(out, [nil], [nil], curve, params(la: 4), t, st, Numo::DFloat.zeros(2)) }.to raise_error(ArgumentError, /Delay/)
      expect { fast.compand(out, [nil], [nil], curve, params, t, Numo::DFloat.zeros(1), nil) }.to raise_error(ArgumentError, /State/)
      expect { fast.compand([Numo::DFloat.zeros(4)], [nil], [nil], curve, params, t, st, nil) }.to raise_error(ArgumentError, /SFloat/)
      expect { fast.compand(out, [nil], [nil], curve, params, [0, 0], st, nil) }.to raise_error(ArgumentError, /times/)
      expect { fast.compand(out, [Numo::SFloat.zeros(3)], [nil], curve, params, t, st, nil) }.to raise_error(ArgumentError)
    end
  end

  describe '.limit' do
    let(:lim) { MB::Sound::GraphNode::Dynamics::Limiter }
    let(:phases) { lim.phases }

    def compare(nch, ins, la:, tp:, link:, blocks:)
      ndet = link ? 1 : nch
      w = la + 1
      prm = Numo::DFloat[0.5, Math.exp(-1.0 / 300), la, tp ? 1 : 0, link ? 1 : 0]
      sa = Numo::DFloat.zeros(ndet + nch + 1)
      sa[0...ndet] = 1
      sb = sa.dup
      ra = Numo::DFloat.zeros(2 * ndet * w + nch * la + nch * 12)
      ra[0...(2 * ndet * w)] = 1
      rb = ra.dup
      off = 0
      outs = []
      blocks.each do |len|
        a = Array.new(nch) { Numo::SFloat.zeros(len) }
        b = Array.new(nch) { Numo::SFloat.zeros(len) }
        i = ins.map { |v| v.is_a?(Numo::NArray) ? v[off...(off + len)] : v }
        fast.limit(a, i, prm, sa, ra, phases)
        lim.process_ruby(b, i, prm, sb, rb, phases)
        expect(a).to eq(b)
        expect(sa).to eq(sb)
        expect(ra).to eq(rb)
        outs << a.map(&:dup)
        off += len
      end
      outs
    end

    it 'matches the Ruby mirror with and without true peak and linking' do
      x = bursty(500, level: 2)
      y = bursty(500, level: 0.7)
      [[true, true], [false, true], [true, false], [false, false]].each do |tp, link|
        outs = compare(2, [x, y], la: 12, tp: tp, link: link, blocks: [1, 99, 400])
        expect(outs.flat_map { |o| o.map { |c| c.abs.max } }.max).to be <= 0.5
      end
      compare(1, [x], la: 0, tp: true, link: true, blocks: [500])
      compare(1, [nil], la: 3, tp: false, link: true, blocks: [10])
    end

    it 'rejects bad arguments' do
      out = [Numo::SFloat.zeros(4)]
      prm = Numo::DFloat[0.5, 0.9, 2, 1, 1]
      st = Numo::DFloat.zeros(3)
      expect { fast.limit(out, [nil], prm, st, Numo::DFloat.zeros(3), phases) }.to raise_error(ArgumentError, /Rings/)
      expect { fast.limit(out, [nil], prm, st, Numo::DFloat.zeros(100), Numo::DFloat.zeros(47)) }.to raise_error(ArgumentError, /Phases/)
      expect { fast.limit(out, [nil], Numo::DFloat[0, 0.9, 2, 1, 1], st, Numo::DFloat.zeros(100), phases) }.to raise_error(ArgumentError, /Ceiling/)
    end
  end

  describe '.crossover' do
    let(:xo) { MB::Sound::GraphNode::Dynamics::Crossover }

    [2, 4, 8].each do |order|
      it "matches the Ruby mirror for LR#{order} with 1 and 3 crossovers" do
        [[500], [100, 1000, 8000]].each do |freqs|
          node = xo.new(1.constant, freqs, order: order)
          program, bands, regs = node.program
          x = bursty(300)
          sa = Numo::DFloat.zeros(program.length / 9 * 2)
          sb = sa.dup
          [[0, 111], [111, 189]].each do |off, len|
            a = Array.new(bands.length) { Numo::SFloat.zeros(len) }
            b = Array.new(bands.length) { Numo::SFloat.zeros(len) }
            fast.crossover(a, x[off...(off + len)], program, bands, sa, regs)
            xo.process_ruby(b, x[off...(off + len)], program, bands, sb, regs)
            expect(a).to eq(b)
            expect(sa).to eq(sb)
          end
        end
      end
    end

    it 'rejects bad programs' do
      out = [Numo::SFloat.zeros(4)]
      st = Numo::DFloat.zeros(2)
      expect { fast.crossover(out, nil, Numo::DFloat[0, 9, 0, 0, 1, 0, 0, 1, 1], [1], st, 2) }.to raise_error(ArgumentError, /register/)
      expect { fast.crossover(out, nil, Numo::DFloat[0, 1, 0, 9, 1, 0, 0, 1, 1], [1], st, 2) }.to raise_error(ArgumentError, /kind/)
      expect { fast.crossover(out, nil, Numo::DFloat[0, 1, 0, 1, 1, 0, 0, 1, 1], [5], st, 2) }.to raise_error(ArgumentError, /Band/)
      expect { fast.crossover(out, nil, Numo::DFloat[0, 1, 0, 1, 1, 0, 0, 1, 1], [1, 1], st, 2) }.to raise_error(ArgumentError, /one band/)
    end
  end
end
