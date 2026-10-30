RSpec.describe('MB::Sound::FastSampler.grains', :aggregate_failures) do
  let(:mirror) { MB::Sound::Granular::KernelRuby }

  def tone(n, freq: 300, seed: 3)
    r = Random.new(seed)
    Numo::SFloat.cast(Array.new(n) { |i| Math.sin(i * 2 * Math::PI * freq / 48000) * 0.7 + (r.rand - 0.5) * 0.3 })
  end

  # A node of single-sample 1s at absolute sample indices +at+.
  def impulses(*at)
    Class.new {
      include MB::Sound::GraphNode
      include MB::Sound::GraphNode::SampleRateHelper
      define_method(:initialize) { @t = 0; @sample_rate = 48000.0 }
      define_method(:sources) { {} }
      define_method(:sample) { |n|
        b = Numo::SFloat.zeros(n)
        at.each { |i| b[i - @t] = 1 if i >= @t && i < @t + n }
        @t += n
        b
      }
    }.new
  end

  let(:mono) { MB::Sound::Sample[tone(4000)] }
  let(:stereo) { MB::Sound::Sample[[tone(4000), tone(4000, freq: 450, seed: 4)]] }

  # Runs the C kernel and the Ruby mirror on twin Grains nodes over +sizes+
  # blocks, expecting identical outputs and states.  Returns the C output.
  def compare(sample, sizes: [1, 7, 128, 33, 200], **options)
    a = MB::Sound::GraphNode::Grains.new(sample, seed: 11, **options)
    b = MB::Sound::GraphNode::Grains.new(sample, seed: 11, **options)
    out = [[], []]
    sizes.each do |n|
      l = a.outputs[0].sample(n).dup
      r = a.outputs[1].sample(n).dup
      rl, rr = MB::Sound::Kernels.with(:ruby) { [b.outputs[0].sample(n).dup, b.outputs[1].sample(n).dup] }
      expect(l.to_a).to eq(rl.to_a)
      expect(r.to_a).to eq(rr.to_a)
      out[0].concat(l.to_a)
      out[1].concat(r.to_a)
    end
    %i[@slots @state @rng].each { |iv| expect(a.instance_variable_get(iv).to_a).to eq(b.instance_variable_get(iv).to_a) }
    out
  end

  it 'matches the Ruby mirror for a plain mono cloud' do
    out = compare(mono, density: 400, size: 0.004)
    expect(out[0].map(&:abs).max).to be > 0.1
  end

  it 'matches the Ruby mirror for a stereo sample with every random parameter' do
    compare(stereo, density: 600, size: 0.003, position: 0.3, spread: 0.2, pitch: [0, 12, -5], pitch_spread: 0.7, pan_spread: 1,
            reverse: 0.5, jitter: 0.4, window: :expodec)
  end

  it 'matches the Ruby mirror for node inputs, key tracking, triggers, and a scan' do
    trig = impulses(3, 140, 141, 300)
    out = compare(mono.rev.trim(100...3500).transpose(2), density: 300.hz.lfo.at(200..900), size: 30.hz.lfo.at(0.002..0.005), scan: 0.5,
                  freq: 50.hz.lfo.at(200..300), trigger: trig, pitch: 7.hz.lfo.at(-3..3), max_grains: 3)
    expect(out[0].map(&:abs).max).to be > 0
  end

  it 'matches the Ruby mirror with drop-sample reads, cubic, and sinc' do
    compare(mono.read_as(:drop), density: 500, size: 0.003, pitch: 5)
    compare(mono, density: 500, size: 0.003, pitch: 9, interpolation: :cubic)
    compare(mono, density: 500, size: 0.003, pitch: 3, interpolation: :sinc, sizes: [64, 100])
  end

  it 'matches the Ruby mirror for every window' do
    MB::Sound::Granular::WINDOWS.each_key { |w| compare(mono, density: 800, size: 0.002, window: w, sizes: [50, 150]) }
  end

  it 'raises on bad arguments' do
    g = MB::Sound::GraphNode::Grains.new(mono, seed: 1)
    specs = g.instance_variable_get(:@specs)
    slots = Numo::DFloat.zeros(4, MB::Sound::FastSampler::GRAIN_COLS)
    state = Numo::DFloat[1, 1, 0]
    rng = Numo::UInt64[1]
    win = MB::Sound::Granular.window(:hann)
    inputs = [0.0, 20.0, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, nil, 0.0, 1.0]
    config = g.send(:config)
    l = Numo::SFloat.zeros(8)
    r = Numo::SFloat.zeros(8)
    fast = MB::Sound::FastSampler
    expect(fast.grains(l, r, specs, slots, state, rng, win, inputs, config)).to equal(l)
    expect { fast.grains(l, Numo::SFloat.zeros(7), specs, slots, state, rng, win, inputs, config) }.to raise_error(ArgumentError, /same length/)
    expect { fast.grains(l, r, specs, Numo::DFloat.zeros(4, 3), state, rng, win, inputs, config) }.to raise_error(ArgumentError, /columns/)
    expect { fast.grains(l, r, specs, slots, Numo::DFloat[1, 1], rng, win, inputs, config) }.to raise_error(ArgumentError, /state/)
    expect { fast.grains(l, r, specs, slots, state, rng, Numo::DFloat.zeros(10), inputs, config) }.to raise_error(ArgumentError, /window/)
    expect { fast.grains(l, r, specs, slots, state, rng, win, inputs[0..10], config) }.to raise_error(ArgumentError, /inputs/)
    expect { fast.grains(l, r, specs, slots, state, rng, win, inputs, config[0..12]) }.to raise_error(ArgumentError, /config/)
    expect { fast.grains(l, r, specs * 3, slots, state, rng, win, inputs, config) }.to raise_error(ArgumentError, /one or two/)
    bad = config.dup
    bad[8] = 1e9
    expect { fast.grains(l, r, specs, slots, state, rng, win, inputs, bad) }.to raise_error(ArgumentError, /region/)
    bad_slots = Numo::DFloat.zeros(4, MB::Sound::FastSampler::GRAIN_COLS)
    bad_slots[0, 0] = 1
    expect { fast.grains(l, r, specs, bad_slots, state, rng, win, inputs, config) }.to raise_error(ArgumentError, /age or length/)
  end
end
