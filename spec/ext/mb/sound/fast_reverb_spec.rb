RSpec.describe(MB::Sound::FastReverb::Network) do
  # A small random network config (lines, stages) with every feature
  # optionally switched on.
  def config(lines: 4, stages: 2, feedback: true, diff_mod: false, fdn_mod: false, damp: false, seed: 3, extra: 0, diff_shape: 3, fdn_shape: 0, drive_mode: 0, dynamics: false)
    rng = Random.new(seed)
    sn = lines * stages
    taps = Array.new(lines) { rng.rand(20..60) }
    normal = Array.new(lines) { rng.rand(0.2..1.0) * (rng.rand > 0.5 ? 1 : -1) }
    norm = Math.sqrt(normal.sum { |v| v * v })
    {
      lines: lines,
      stages: stages,
      sample_rate: 48000.0,
      feedback: feedback,
      seed: seed * 7919,
      diff_scale: 1.0 / Math.sqrt(lines),
      diff_mod: diff_mod,
      fdn_mod: fdn_mod,
      diff_shape: diff_shape,
      fdn_shape: fdn_shape,
      drive_mode: drive_mode,
      shimmer_window: 24,
      in_gain: Array.new(lines) { 1.0 / Math.sqrt(lines) },
      diff_delay: Array.new(sn) { rng.rand(0..12).to_f },
      diff_polarity: Array.new(sn) { rng.rand > 0.5 ? 1.0 : -1.0 },
      diff_order: Array.new(stages) { (0...lines).to_a.shuffle(random: rng) }.flatten,
      diff_capacity: Array.new(sn, 40),
      tap: taps.map(&:to_f),
      loop: taps.map { |t| (t + extra).to_f },
      gain: Array.new(lines) { rng.rand(0.5..0.9) },
      normal: normal.map { |v| v / norm },
      order: (0...lines).to_a.shuffle(random: rng),
      fdn_capacity: Array.new(lines, 200),
      damp_coeffs: damp ? Array.new(lines) { rng.rand(0.3..0.9) } : nil,
      diff_rate_scale: Array.new(sn) { rng.rand(0.7..1.3) },
      diff_phase: Array.new(sn) { rng.rand },
      fdn_rate_scale: Array.new(lines) { rng.rand(0.7..1.3) },
      fdn_phase: Array.new(lines) { rng.rand },
      shimmer_phase: Array.new(lines) { |i| i.to_f / lines },
      dynamics: dynamics,
    }
  end

  # Default parameters: no modulation, no processing.
  def params(**over)
    p = {
      diffusion_depth: 0, diffusion_rate: 0, depth: 0, rate: 0, lowpass: 0, highpass: 0,
      drive: 0, shimmer: 0, shimmer_ratio: 2.0, freeze: 0, stretch: 1.0, crush: 0, duck: 0, gate: 0, threshold: 0.1,
    }.merge(over)
    MB::Sound::GraphNode::Reverb::Network::PARAMS.map { |name, _| p.fetch(name) }
  end

  def run(klass, cfg, blocks, par, lines)
    net = klass.new(cfg)
    rng = Random.new(42)
    blocks.flat_map { |count|
      inputs = Array.new(lines) { |j| j.even? ? Numo::SFloat.new(count).rand(-1, 1) : 0.25 }
      par_now = par.respond_to?(:call) ? par.call(count) : par
      outs = Array.new(lines) { Numo::SFloat.zeros(count) }
      net.process(inputs, outs, par_now, count)
      [outs.map(&:dup)]
    }.then { |list| list.transpose.map { |c| c[0].concatenate(*c[1..]) } }
  end

  def compare(cfg, par, blocks: [37, 64, 1, 200, 16], lines: cfg[:lines])
    Numo::NArray.srand(5)
    c = run(described_class, cfg, blocks, par, lines)
    Numo::NArray.srand(5)
    r = run(MB::Sound::GraphNode::Reverb::Network::RubyKernel, cfg, blocks, par, lines)
    expect(c.map(&:to_a)).to eq(r.map(&:to_a))
    expect(c.map { |v| v.abs.max }.max).to be > 0
    c
  end

  it 'matches the Ruby mirror without modulation or processing' do
    compare(config, params)
  end

  it 'matches the Ruby mirror with a loop longer than the taps' do
    compare(config(extra: 17), params)
  end

  it 'matches the Ruby mirror without feedback or diffusion' do
    compare(config(feedback: false), params)
    compare(config(stages: 0), params)
    compare(config(lines: 1, stages: 1), params)
  end

  [[0, 0], [1, 2], [3, 1], [2, 3]].each do |ds, fs|
    it "matches the Ruby mirror with modulation (shapes #{ds}, #{fs})" do
      compare(config(diff_mod: true, fdn_mod: true, diff_shape: ds, fdn_shape: fs, lines: 8), params(diffusion_depth: 3.5, diffusion_rate: 300, depth: 6.25, rate: 210.5))
    end
  end

  it 'matches the Ruby mirror with every insert' do
    [0, 1, 2].each do |mode|
      compare(config(fdn_mod: true, drive_mode: mode), params(depth: 2, rate: 50, lowpass: 3000, highpass: 120, drive: 3, shimmer: 0.6, shimmer_ratio: 2.0, crush: 6, stretch: 1.3))
    end
  end

  it 'matches the Ruby mirror with per-line damping, freeze, and parameter buffers' do
    par = ->(count) {
      params(
        lowpass: Numo::SFloat.new(count).seq(500, 7),
        freeze: Numo::SFloat.new(count).seq(0, 0.01),
        stretch: Numo::SFloat.new(count).seq(0.8, 0.003),
        depth: Numo::SFloat.new(count).fill(4),
        rate: 100,
      )
    }
    compare(config(fdn_mod: true, damp: true), par)
    compare(config(fdn_mod: true), par)
  end

  it 'matches the Ruby mirror with ducking and a gate' do
    compare(config(dynamics: true), params(duck: 12, threshold: 0.5))
    compare(config(dynamics: true, feedback: false), params(gate: 0.0005, threshold: 0.7))
    par = ->(count) { params(duck: Numo::SFloat.new(count).seq(0, 0.1), gate: 0.001, threshold: Numo::SFloat.new(count).fill(0.6)) }
    compare(config(dynamics: true), par)
  end

  it 'gives the same samples at every block size' do
    cfg = config(diff_mod: true, fdn_mod: true, lines: 8)
    par = params(diffusion_depth: 2, diffusion_rate: 400, depth: 5, rate: 333, lowpass: 4000, drive: 2, shimmer: 0.3)
    ref = run(described_class, cfg, [2000], par, 8)
    [[1] * 300 + [1700], [7] * 285 + [5], [16] * 125, [1999, 1], [333, 667, 1000]].each do |blocks|
      Numo::NArray.srand(0)
      # Same input values in every split: generate one input and slice it
      expect(run_split(cfg, par, blocks, 8)).to eq(run_split(cfg, par, [2000], 8))
    end
    expect(ref[0].abs.max).to be > 0
  end

  def run_split(cfg, par, blocks, lines)
    total = blocks.sum
    rng = Random.new(9)
    input = Array.new(lines) { Numo::SFloat.cast(Array.new(total) { rng.rand(-1.0..1.0) }) }
    net = described_class.new(cfg)
    done = 0
    blocks.flat_map { |count|
      outs = Array.new(lines) { Numo::SFloat.zeros(count) }
      net.process(input.map { |c| c[done...(done + count)].dup }, outs, par, count)
      done += count
      [outs.map(&:dup)]
    }.then { |list| list.transpose.map { |c| c[0].concatenate(*c[1..]) } }
  end

  it 'mixes with a normalized Hadamard matrix (one stage, no delay)' do
    cfg = config(lines: 4, stages: 1, feedback: false)
    cfg[:diff_delay] = [0.0] * 4
    cfg[:diff_polarity] = [1.0] * 4
    cfg[:diff_order] = [0, 1, 2, 3]
    cfg[:in_gain] = [1.0] * 4
    net = described_class.new(cfg)
    inputs = [1, 2, 3, 4].map { |v| Numo::SFloat[v] }
    outs = Array.new(4) { Numo::SFloat.zeros(1) }
    net.process(inputs, outs, params, 1)
    h = Matrix[*MB::M.hadamard(4)] * Vector[1, 2, 3, 4] * 0.5
    expect(outs.map { |o| o[0] }).to eq(h.to_a.map(&:to_f))
  end

  it 'keeps a lossless network ringing when frozen' do
    cfg = config(lines: 4, stages: 1)
    net = described_class.new(cfg)
    imp = Numo::SFloat.zeros(200)
    imp[0] = 1
    outs = Array.new(4) { Numo::SFloat.zeros(200) }
    net.process([imp, 0, 0, 0], outs, params, 200)

    # Frozen: the input is muted and the loop gains are 1, so the energy in
    # the loop stays put
    energy = Array.new(3) {
      outs = Array.new(4) { Numo::SFloat.zeros(4800) }
      net.process([1, 1, 1, 1], outs, params(freeze: 1), 4800)
      outs.sum { |o| (Numo::DFloat.cast(o) ** 2).sum }
    }
    expect(energy[0]).to be > 1e-6
    expect(energy[2]).to be_within(energy[0] * 0.01).of(energy[0])
  end

  it 'refuses bad configs' do
    expect { described_class.new(config.merge(lines: 3)) }.to raise_error(ArgumentError, /power of two/)
    expect { described_class.new(config.merge(diff_order: [9] * 8)) }.to raise_error(ArgumentError, /out of range/)
    expect { described_class.new(config.reject { |k, _| k == :gain }) }.to raise_error(ArgumentError, /gain/)
    expect { described_class.new(config).process([0] * 3, [], params, 1) }.to raise_error(ArgumentError)
    net = described_class.new(config)
    expect { net.process([0] * 4, Array.new(4) { Numo::SFloat.zeros(2) }, params, 3) }.to raise_error(ArgumentError, /at least 3/)
  end
end
