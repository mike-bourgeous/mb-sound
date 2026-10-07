RSpec.describe(MB::Sound::GraphNode::CurveShaper) do
  CS = MB::Sound::GraphNode::CurveShaper unless defined?(CS)

  # A test signal that crosses the input range and jumps around: a loud
  # sine plus a ramp, with a few repeated samples (the midpoint branch).
  def signal(n = 1200)
    x = Numo::DFloat.new(n).seq
    s = Numo::NMath.sin(x * 0.07) * 1.6 + (x / n - 0.5) * 0.8
    s[100..110] = 0.25
    s[500] = 3.0
    Numo::SFloat.cast(s)
  end

  CURVES = [
    :smoothstep, :smootherstep, :linear, :sine, :sine_in, :quad, :exp, :exp_in, :back,
    :elastic, :bounce, :squiggle, :steps, :ease, :anticipate,
  ].freeze

  it 'matches its Ruby mirror sample for sample (every form and edge mode)' do
    CURVES.each do |name|
      curve = MB::Sound::Curve[name]
      CS::EDGES.each_key do |edges|
        [false, true].each do |sym|
          next if edges == :none && curve.form.nil?

          node = CS.new(MB::Sound::ArrayInput.new(data: [signal]), curve: curve, input: -1..1, output: -1..1, edges: edges, symmetric: sym)
          c = 3.times.map { node.sample(400).dup }.reduce(:concatenate)
          params = node.instance_variable_get(:@params)
          state = [0.0, 0.0, 0.0, 0]
          r = signal.to_a.each_slice(400).map { |s| CS.shape_ruby(Numo::SFloat.cast(s), params, sym, state) }.reduce(:concatenate)
          expect(c).to eq(r), "#{name} #{edges} #{sym}"
        end
      end
    end
  end

  it 'is exact with antialias: false (#aease)' do
    sig = Numo::SFloat[0, 0.1, 0.25, 0.5, 0.9, 1.0, 1.5]
    out = MB::Sound::ArrayInput.new(data: [sig]).aease(:steps, cycles: 4).sample(7)
    expect(out.to_a).to eq([0, 0.25, 0.25, 0.5, 1, 1, 1])

    sm = MB::Sound::ArrayInput.new(data: [sig]).aease.sample(7)
    expect((sm - Numo::SFloat.cast(sig.to_a.map { |v| v = v.clamp(0, 1); MB::M.smoothstep(v) })).abs.max).to eq(0)
  end

  it 'maps input and output ranges' do
    out = MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, 0, 1]]).aease(:linear, in: -1..1, out: 100..300).sample(3)
    expect(out.to_a).to eq([100, 200, 300])
    out = MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, -0.5, 0.5, 1]]).aease(:quad, symmetric: true, out: 2).sample(4)
    expect(out.to_a).to eq([-2, -0.5, 0.5, 2])
  end

  it 'antialiases with half a sample of delay and a flat level' do
    # A slow sine through the smoothstep: close to the plain shaper at the
    # midpoint of each pair of samples
    t = Numo::DFloat.new(4800).seq
    x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * 50 / 48000) * 0.5 + 0.5)
    node = MB::Sound::ArrayInput.new(data: [x]).ease
    out = node.sample(4800)
    mid = (x[1..] + x[0...-1]) * 0.5
    expect((out[1..] - node.plain(mid)).abs.max).to be < 1e-3
  end

  it 'reduces aliasing of a jumpy curve' do
    n = 65536
    k = 1367
    t = Numo::DFloat.new(n).seq
    x = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * k / n))
    nonharmonic = ->(y) {
      spec = (Numo::Pocketfft.rfft(Numo::DFloat.cast(y)).abs**2)
      h = Numo::Bit.zeros(spec.length)
      (k...spec.length).step(k) { |i| h[i] = 1 }
      10 * Math.log10(spec[~h][1..].sum / spec[h].sum)
    }
    plain = nonharmonic.(MB::Sound::ArrayInput.new(data: [x]).aease(:steps, cycles: 8, range: -1..1).sample(n))
    aa = nonharmonic.(MB::Sound::ArrayInput.new(data: [x]).ease(:steps, cycles: 8, range: -1..1).sample(n))
    expect(aa).to be < plain - 10
  end

  it 'rejects :none with a table curve when antialiased' do
    expect { 1.constant.ease(:elastic, edges: :none) }.to raise_error(ArgumentError, /closed-form/)
    expect(1.constant.aease(:elastic, edges: :none).sample(2).to_a).to eq([1, 1])
  end

  it 'works on channel bundles' do
    b = MB::Sound.stereo(0.5.constant, 0.25.constant).aease(:quad)
    expect(b.map { |c| c.sample(1)[0] }).to eq([0.25, 0.0625])
  end
end

RSpec.describe('MB::Sound::FastClip.shape_curve arguments') do
  let(:map) { Numo::DFloat[0, 1, 0, 1, 0, 1, 0, 0, 0.5, 0] }

  it 'rejects bad forms, edges, tables, and coefficients' do
    buf = Numo::SFloat[0, 0.5]
    st = [0.0, 0.0, 0.0, 0]
    expect { MB::Sound::FastClip.shape_curve(buf, 9, Numo::DFloat[0, 1], nil, nil, nil, map, 0, false, st) }.to raise_error(ArgumentError, /form/)
    expect { MB::Sound::FastClip.shape_curve(buf, 1, Numo::DFloat[0, 1], nil, nil, nil, map, 7, false, st) }.to raise_error(ArgumentError, /edge/)
    expect { MB::Sound::FastClip.shape_curve(buf, 0, nil, nil, nil, nil, map, 0, false, st) }.to raise_error(ArgumentError, /table/)
    expect { MB::Sound::FastClip.shape_curve(buf, 2, Numo::DFloat[0, 1], nil, nil, nil, map, 0, false, st) }.to raise_error(ArgumentError, /coefficients/)
    expect { MB::Sound::FastClip.shape_curve(buf, 1, Numo::SFloat[0, 1], nil, nil, nil, map, 0, false, st) }.to raise_error(ArgumentError, /DFloat/)
    expect { MB::Sound::FastClip.shape_curve(buf, 1, Numo::DFloat[0, 1], nil, nil, nil, Numo::DFloat[0, 1], 0, false, st) }.to raise_error(ArgumentError, /short/)
    expect { MB::Sound::FastClip.shape_curve(buf, 1, Numo::DFloat[0, 1], nil, nil, nil, map, 0, false, [0.0]) }.to raise_error(ArgumentError, /state/)
    # A straight line is only the half-sample allpass (0.5 / 3 on the step)
    out = MB::Sound::FastClip.shape_curve(buf, 1, Numo::DFloat[0, 1], nil, nil, nil, map, 0, false, st)
    expect(out.to_a).to match([0, be_within(1e-7).of(0.5 / 3)])
  end
end
