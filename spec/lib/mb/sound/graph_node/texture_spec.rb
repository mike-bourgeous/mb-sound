RSpec.describe('texture nodes', :aggregate_failures) do
  # Samples +node+ in buffers of the given sizes (cycled) until +total+
  # samples.
  def collect(node, total, sizes = [800])
    out = []
    got = 0
    sizes.cycle do |s|
      break if got >= total
      buf = node.sample([s, total - got].min)
      break if buf.nil?
      out << buf.dup
      got += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  describe MB::Sound::GraphNode::Dust do
    it 'makes sparse impulses at about the rate, heights in the range' do
      out = collect(MB::Sound.dust(100, seed: 3), 480000)
      hits = out[out.ne(0)]
      expect(hits.length).to be_within(100).of(1000)
      expect(hits.min).to be > 0
      expect(hits.max).to be <= 1

      bi = collect(MB::Sound.dust(100, bipolar: true, seed: 3), 48000)
      expect(bi.min).to be < -0.3
      expect(bi.max).to be > 0.3

      fixed = collect(MB::Sound.dust(100, range: 0.8..0.8, seed: 3), 48000)
      expect(fixed[fixed.ne(0)].to_a.uniq).to eq([Numo::SFloat[0.8][0]])
    end

    it 'repeats from its seed and draws a new seed from the root generator otherwise' do
      expect(collect(MB::Sound.dust(300, seed: 9), 4800)).to eq(collect(MB::Sound.dust(300, seed: 9), 4800))

      MB::Sound.seed(1)
      a = collect(MB::Sound.dust(300), 4800)
      b = collect(MB::Sound.dust(300), 4800)
      MB::Sound.seed(1)
      c = collect(MB::Sound.dust(300), 4800)
      expect(a).not_to eq(b)
      expect(a).to eq(c)
    end

    it 'gives the same samples at any buffer size, with a moving rate' do
      make = -> { MB::Sound.dust(1.hz.lfo.triangle.at(10..2000), seed: 4) }
      a = collect(make.(), 20000)
      b = collect(make.(), 20000, [1, 7, 128, 333, 800])
      expect(a).to eq(b)
    end

    it 'takes the average time between impulses as a length' do
      out = collect(MB::Sound.dust(10.ms, seed: 3), 480000)
      expect(out.ne(0).count_true).to be_within(100).of(1000)
      expect(collect(MB::Sound.dust(100.hz, seed: 3), 4800)).to eq(collect(MB::Sound.dust(100, seed: 3), 4800))
    end

    it 'ends when its rate node ends' do
      node = MB::Sound.dust(MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(1000).fill(500)]), seed: 1)
      expect(collect(node, 4800).length).to eq(1000)
    end

    it 'strikes a resonator at the impulse heights' do
      out = collect(MB::Sound.dust(5, range: 0.5..0.5, seed: 2).ping(6000, decay: 0.01), 96000)
      expect(out.abs.max).to be_within(0.01).of(0.49)
    end

    it 'raises for bad arguments' do
      expect { MB::Sound.dust('x') }.to raise_error(ArgumentError, /rate/)
      expect { MB::Sound.dust(5, range: [0, 1]) }.to raise_error(ArgumentError, /range/)
    end
  end

  # The length of the flat run starting at +start+.
  def share_run(out, start)
    v = out[start]
    n = 0
    n += 1 while start + n < out.length && out[start + n] == v
    n
  end

  describe 'Dust min_gap' do
    it 'keeps strikes at least the gap apart at the same average rate, as seconds, Lengths, and Durations' do
      [0.25, 250.ms, 12000.samples].each do |gap|
        out = collect(MB::Sound.dust(2, min_gap: gap, seed: 5), 48000 * 60)
        hits = out.ne(0).where.to_a
        expect(hits.each_cons(2).map { |a, b| b - a }.min).to be >= 12000
        expect(hits.length).to be_within(25).of(120)
      end
      MB::Sound::Sequence::Transport.new(bpm: 120).then do |tr|
        MB::Sound::Session.with_context(transport: tr) do
          out = collect(MB::Sound.dust(8, min_gap: 1.n8, seed: 5), 48000 * 10) # 0.25 s at 120 BPM
          hits = out.ne(0).where.to_a
          expect(hits.each_cons(2).map { |a, b| b - a }.min).to be >= 12000
        end
      end
    end

    it 'is the same dust with no gap, and the same at any buffer size with one' do
      expect(collect(MB::Sound.dust(300, min_gap: 0, seed: 3), 4800)).to eq(collect(MB::Sound.dust(300, seed: 3), 4800))
      a = collect(MB::Sound.dust(30, min_gap: 20.ms, seed: 3), 48000)
      b = collect(MB::Sound.dust(30, min_gap: 20.ms, seed: 3), 48000, [1, 7, 128, 333, 800])
      expect(a).to eq(b)
      expect(MB::Sound.dust(3, min_gap: 0.1).to_s).to include('min gap')
    end

    it 'prints and reloads its gap' do
      node = MB::Sound.dust(2, min_gap: 1.n16, seed: 4)
      expect(node.to_ruby).to eq('dust(2, min_gap: 1.n16, seed: 4)')
    end

    it 'raises for bad gaps' do
      expect { MB::Sound.dust(1, min_gap: -1) }.to raise_error(ArgumentError, /min_gap/)
      expect { MB::Sound.dust(1, min_gap: 'x') }.to raise_error(ArgumentError, /min_gap/)
    end
  end

  describe MB::Sound::GraphNode::Drift do
    describe 'curves, holds, jitter, and from:' do
      let(:back) { MB::Sound::Curve[:back, overshoot: 0.4] }

      it 'moves along any Curve, meeting the step values at each point, overshooting with :back' do
        step = collect(MB::Sound.drift(10, smooth: :step, seed: 7), 48000)
        curved = collect(MB::Sound.drift(10, smooth: back, seed: 7), 48000)
        named = collect(MB::Sound.drift(10, smooth: :ease_in_out, seed: 7), 48000)
        (0...10).each do |k|
          expect(curved[k * 4800]).to eq(step[k * 4800])
          expect(named[k * 4800]).to eq(step[k * 4800])
        end
        wild = collect(MB::Sound.drift(50, smooth: MB::Sound::Curve[:elastic, overshoot: 0.6], seed: 7), 48000)
        expect(wild.min < -1 || wild.max > 1).to eq(true) # not clamped
        expect(MB::Sound.drift(1, smooth: back).to_s).to include('back(0.4)')
      end

      it 'rests on each point for the hold: shares, times, random ranges, and nodes' do
        share = collect(MB::Sound.drift(10, smooth: :linear, hold: 0.25, seed: 7), 48000)
        timed = collect(MB::Sound.drift(10, smooth: :linear, hold: 25.ms, seed: 7), 48000)
        expect(timed).to eq(share)
        (0...10).each { |k| expect(share[(k * 4800)...(k * 4800 + 1200)].to_a.uniq.length).to eq(1) }

        random = collect(MB::Sound.drift(10, smooth: :linear, hold: 0.1..0.9, seed: 7), 48000)
        flats = (0...10).map { |k| share_run(random, k * 4800) }
        expect(flats.min).to be >= 480
        expect(flats.max).to be <= 4320 + 1
        expect(flats.uniq.length).to be > 5

        knob = collect(MB::Sound.drift(10, smooth: :linear, hold: 0.25.constant, seed: 7), 48000)
        expect(knob).to eq(share)
        timed_range = collect(MB::Sound.drift(10, smooth: :linear, hold: 10.ms..80.ms, seed: 7), 48000)
        expect((0...10).map { |k| share_run(timed_range, k * 4800) }.minmax).to satisfy { |lo, hi| lo >= 480 && hi <= 3841 }
      end

      it 'spaces the points unevenly with jitter, at about the same average rate' do
        out = collect(MB::Sound.drift(20, smooth: :step, jitter: 1, seed: 7), 48000 * 20)
        gaps = (1...out.length).select { |i| out[i] != out[i - 1] }.each_cons(2).map { |a, b| b - a }
        expect(gaps.length).to be_within(60).of(400)
        expect(gaps.minmax).to satisfy { |lo, hi| lo < 600 && hi > 6000 }
        knob = collect(MB::Sound.drift(20, smooth: :step, jitter: 1.constant, seed: 7), 48000)
        expect(knob).to eq(out[0...48000])
      end

      it 'keeps its points whatever hold, jitter, and smooth are' do
        visits = ->(o) { o.to_a.chunk_while { |x, y| x == y }.map(&:first) }
        plain = visits.(collect(MB::Sound.drift(20, smooth: :step, walk: 0.3, seed: 7), 48000))
        held = visits.(collect(MB::Sound.drift(20, smooth: :step, walk: 0.3, hold: 0.1..0.9, seed: 7), 48000))
        jit = visits.(collect(MB::Sound.drift(20, smooth: :step, walk: 0.3, jitter: 0.8, hold: 0.5, seed: 7), 48000 * 3))
        expect(held).to eq(plain)
        expect(jit.first(plain.length)).to eq(plain)
      end

      it 'starts from: a value' do
        out = collect(MB::Sound.drift(1, range: 100..200, smooth: :cosine, from: 150, seed: 7), 4800)
        expect(out[0]).to eq(150)
        expect(MB::Sound.drift(1, from: 0, smooth: back, seed: 3).sample(1)[0]).to eq(0)
      end

      it 'gives the same samples at any buffer size with everything moving' do
        make = -> { MB::Sound.drift(0.5.hz.lfo.at(5..60), walk: 0.4, hold: 5.ms..30.ms, jitter: 2.hz.lfo.at(0..1), smooth: back, seed: 4) }
        a = collect(make.(), 30000)
        b = collect(make.(), 30000, [1, 7, 128, 333, 800])
        expect(a).to eq(b)
      end

      it 'prints and reloads as a graph document' do
        node = MB::Sound.drift(2, walk: 0.4, hold: 50.ms..300.ms, jitter: 0.5, smooth: back, from: 0, seed: 3)
        expect(node.to_ruby).to eq('drift(2, walk: 0.4, hold: 50.ms..300.ms, jitter: 0.5, smooth: Curve[:back, overshoot: 0.4], from: 0, seed: 3)')
        loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(node, name: 'creature'))
        expect(collect(loaded, 48000)).to eq(collect(MB::Sound.drift(2, walk: 0.4, hold: 50.ms..300.ms, jitter: 0.5, smooth: back, from: 0, seed: 3), 48000))
        rev = MB::Sound.drift(1, smooth: MB::Sound::Curve[:bounce].reverse, hold: 0.2..0.4, seed: 1)
        expect(rev.to_ruby).to eq('drift(1, smooth: Curve[:bounce].reverse, hold: 0.2..0.4, seed: 1)')
        expect(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(rev, name: 'r')).to_s).to eq(rev.to_s)
      end

      it 'raises for bad holds, jitters, and starts' do
        expect { MB::Sound.drift(1, hold: 2) }.to raise_error(ArgumentError, /hold/)
        expect { MB::Sound.drift(1, hold: [0.1, 0.2]) }.to raise_error(ArgumentError, /hold/)
        expect { MB::Sound.drift(1, hold: 'x') }.to raise_error(ArgumentError, /hold/)
        expect { MB::Sound.drift(1, jitter: 1.5) }.to raise_error(ArgumentError, /jitter/)
        expect { MB::Sound.drift(1, jitter: :x) }.to raise_error(ArgumentError, /jitter/)
        expect { MB::Sound.drift(1, from: 3) }.to raise_error(ArgumentError, /from/)
        expect { MB::Sound.drift(1, smooth: nil) }.to raise_error(ArgumentError, /smooth/)
      end
    end

    it 'wanders within its range with every kind of smoothing' do
      MB::Sound::GraphNode::Drift::SMOOTH.each_key do |s|
        out = collect(MB::Sound.drift(50, range: 2..5, smooth: s, seed: 7), 48000)
        expect(out.min).to be >= 2
        expect(out.max).to be <= 5
        expect(out.max - out.min).to be > 1
      end
    end

    it 'shares its points across smoothing kinds, so linear and cosine meet the steps at each point' do
      step = collect(MB::Sound.drift(10, smooth: :step, seed: 7), 48000)
      lin = collect(MB::Sound.drift(10, smooth: :linear, seed: 7), 48000)
      cos = collect(MB::Sound.drift(10, smooth: :cosine, seed: 7), 48000)
      (0...10).each do |k|
        expect(lin[k * 4800]).to eq(step[k * 4800])
        expect(cos[k * 4800]).to eq(step[k * 4800])
      end
      expect(step[0...4800].to_a.uniq.length).to eq(1)
      expect(MB::Sound.drift(1, smooth: :sah).to_s).to include('step')
    end

    it 'is smooth: cubic moves less per sample than linear' do
      lin = collect(MB::Sound.drift(20, smooth: :linear, seed: 7), 48000)
      cub = collect(MB::Sound.drift(20, smooth: :cubic, seed: 7), 48000)
      jerk = ->(x) { (x[2..] - x[1...-1] * 2 + x[0...-2]).abs.max }
      expect(jerk.(cub)).to be < jerk.(lin) / 10
    end

    it 'walks in small steps with walk:' do
      out = collect(MB::Sound.drift(100, smooth: :step, walk: 0.05, seed: 7), 48000)
      steps = (out[480..] - out[0...-480]).abs
      expect(steps.max).to be <= 0.1 + 1e-6 # 0.05 of a range 2 wide
      expect(steps.max).to be > 0.01
    end

    it 'gives the same samples at any buffer size, with moving and tempo rates' do
      [-> { MB::Sound.drift(0.5.hz.lfo.at(5..300), seed: 4) }, -> { MB::Sound.drift(1.n32, seed: 4) }].each do |make|
        a = collect(make.(), 20000)
        b = collect(make.(), 20000, [1, 7, 128, 333, 800])
        expect(a).to eq(b)
      end
    end

    it 'steps every period given as a length' do
      out = collect(MB::Sound.drift(480.samples, smooth: :step, seed: 1), 4800)
      changes = (1...out.length).select { |i| out[i] != out[i - 1] }
      expect(changes).to eq((1..9).map { |k| k * 480 })
    end

    it 'raises for bad arguments' do
      expect { MB::Sound.drift(1, smooth: :wobbly) }.to raise_error(ArgumentError, /smooth/)
      expect { MB::Sound.drift(1, walk: 2) }.to raise_error(ArgumentError, /walk/)
      expect { MB::Sound.drift(1, range: 1.constant..2) }.to raise_error(ArgumentError, /range/)
    end
  end
end
