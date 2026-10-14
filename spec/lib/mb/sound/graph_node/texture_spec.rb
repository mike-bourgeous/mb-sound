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

  describe MB::Sound::GraphNode::Drift do
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
