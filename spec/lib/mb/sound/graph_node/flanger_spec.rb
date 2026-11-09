RSpec.describe(MB::Sound::GraphNode::Flanger, :aggregate_failures) do
  let(:mod) { MB::Sound::GraphNode::Flanger }

  def collect(node, total, size = 800)
    sizes = Array(size).cycle
    out = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      buf = node.sample(len)
      break if buf.nil?
      out << buf.dup
      n += buf.length
    end
    SpecBuffers.join(out)
  end

  # Both sides of a bundle collected in turn, buffer by buffer.
  def collect_stereo(bundle, total, size = 800)
    sizes = Array(size).cycle
    l = []
    r = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      a = bundle.outputs[0].sample(len)
      b = bundle.outputs[1].sample(len)
      break if a.nil? || b.nil?
      l << a.dup
      r << b.dup
      n += a.length
    end
    [SpecBuffers.join(l), SpecBuffers.join(r)]
  end

  def impulse(length = 1)
    d = Numo::SFloat.zeros(length)
    d[0] = 1
    MB::Sound::ArrayInput.new(data: [d])
  end

  # The magnitude response (linear) at +freqs+ of the impulse response of a
  # flanger held at its center (depth 0) with +options+.
  def measured_response(freqs, length: 48000, **options)
    ir = collect(impulse(length).flanger(**{ depth: 0 }.merge(options)), length)
    ir = ir.concatenate(Numo::SFloat.zeros(length - ir.length)) if ir.length < length
    spec = Numo::Pocketfft.rfft(Numo::DFloat.cast(ir[0...length]))
    freqs.map { |f| spec[(f * length / 48000.0).round].abs }
  end

  describe 'comb' do
    it 'cuts notches at odd multiples of 1 / (2 delay) and peaks at multiples of 1 / delay' do
      # 1 ms = 48 samples: notches at 500, 1500, 2500 Hz, peaks at 1000, 2000 Hz
      # (one-second impulse responses: every whole Hz is an rfft bin)
      notches = [500.0, 1500.0, 2500.0]
      peaks = [1000.0, 2000.0, 3000.0]
      n = measured_response(notches, delay: 0.001, feedback: 0, mix: 0.5)
      p = measured_response(peaks, delay: 0.001, feedback: 0, mix: 0.5)
      n.each { |v| expect(v).to be < 1e-3 }
      p.each { |v| expect(v).to be_within(1e-4).of(1) }
    end

    it 'matches dry + wet e^-jwt / (1 - g e^-jwt) for positive and negative feedback' do
      freqs = [250.0, 500.0, 750.0, 1000.0, 1250.0, 3000.0]
      [0.6, -0.6].each do |g|
        got = measured_response(freqs, delay: 0.001, feedback: g, mix: 0.5)
        want = freqs.map { |f|
          z = Complex.polar(1, -2 * Math::PI * f * 0.001)
          (0.5 + 0.5 * z / (1 - g * z)).abs
        }
        got.zip(want).each { |a, b| expect(a).to be_within(1e-3).of(b) }
      end
      # positive feedback peaks at k / t (1 / (1 - g) times the wet), negative at the old notches
      pos = measured_response([1000.0, 500.0], delay: 0.001, feedback: 0.8, mix: 0.5)
      neg = measured_response([1000.0, 500.0], delay: 0.001, feedback: -0.8, mix: 0.5)
      expect(pos[0]).to be_within(1e-3).of(0.5 + 0.5 / 0.2)
      expect(neg[1]).to be_within(1e-3).of((0.5 - 0.5 / 0.2).abs)
      expect(neg[1] / neg[0]).to be > 2
    end

    it 'repeats an impulse every delay, each feedback times the last' do
      out = collect(impulse.flanger(depth: 0, delay: 0.001, feedback: 0.5, mix: 1), 1000)
      expect([0, 48, 96, 144, 192].map { |i| out[i] }).to eq([0, 1, 0.5, 0.25, 0.125])
      out = collect(impulse.flanger(depth: 0, delay: 0.001, feedback: -0.5, mix: 1), 1000)
      expect([48, 96, 144].map { |i| out[i] }).to eq([1, -0.5, 0.25])
    end

    it 'sweeps the delay across delay * 2 ** (+-range / 2), or straight with law: :linear' do
      # a slow sweep node in place of the LFO: -1, 0, 1 at the ends and middle
      ramp = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(-1, 1, 48001)])
      node = 1.constant.flanger(sweep: ramp, delay: 0.002, range: 4, feedback: 0)
      expect(node.graph.grep(MB::Sound::GraphNode::BinaryOperation)).not_to be_empty # (2 ** (sweep * k))
      t = mod.delay_time(MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, 0, 1]]), 0.002, 4.0, 1, :octaves)
      expect(collect(t, 3).to_a).to match([be_within(1e-9).of(0.0005), be_within(1e-9).of(0.002), be_within(1e-8).of(0.008)])
      t = mod.delay_time(MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, 0, 1]]), 0.002, 4.0, 1, :linear)
      expect(collect(t, 3).to_a).to match([be_within(1e-9).of(0.0005), be_within(1e-9).of(0.00425), be_within(1e-8).of(0.008)])
      t = mod.delay_time(MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, 1]]), 0.002, 4.0, 0.5, :octaves)
      expect(collect(t, 2).to_a).to match([be_within(1e-9).of(0.001), be_within(1e-8).of(0.004)])
      expect(mod.sweep_band(nil, 0.5.ms..8.ms, false, 48000)).to match([be_within(1e-12).of(0.002), be_within(1e-12).of(4)])
      expect(mod.sweep_band(2.ms, 4, true, 48000)).to match([be_within(1e-12).of(0.002), 4.0])
    end

    it 'moves its notches with the sweep (a held sweep at each end)' do
      lo = measured_response([1000.0], delay: 0.001, range: 2, sweep: -1.constant, depth: 1, feedback: 0, mix: 0.5) # 0.5 ms
      hi = measured_response([250.0], delay: 0.001, range: 2, sweep: 1.constant, depth: 1, feedback: 0, mix: 0.5)  # 2 ms
      expect(lo[0]).to be < 1e-3
      expect(hi[0]).to be < 1e-3
    end
  end

  describe 'through zero' do
    it 'delays the dry signal by the center, so the held wet lines up with it' do
      out = collect(impulse.flanger(depth: 0, delay: 0.001, feedback: 0, mix: 0.5, through_zero: true), 200)
      expect(out[48]).to eq(1)
      expect(out.abs.sum).to eq(1)
    end

    it 'passes through zero as the sweep crosses the center (no comb there, a comb on each side)' do
      # A held sweep at 0 cancels nothing; at +-1 the comb is back
      zero = measured_response([500.0, 1500.0], delay: 0.001, range: 2, sweep: 0.constant, depth: 1, feedback: 0, mix: 0.5, through_zero: true)
      side = measured_response([500.0, 1500.0], delay: 0.001, range: 2, sweep: 1.constant, depth: 1, feedback: 0, mix: 0.5, through_zero: true) # 1 ms apart
      zero.each { |v| expect(v).to be_within(1e-3).of(1) }
      side.each { |v| expect(v).to be < 1e-3 }
    end
  end

  describe 'stereo' do
    it 'stays mono without spread and makes a mono input stereo with spread' do
      expect(110.hz.saw.flanger).not_to be_a(MB::Sound::GraphNode::Channels)
      st = 110.hz.saw.flanger(spread: 0.5)
      expect(st.channel_count).to eq(2)
      l, r = collect_stereo(st, 24000)
      expect((l - r).abs.max).to be > 0.01
    end

    it 'flanges each side of a stereo input, with or without spread' do
      l, r = collect_stereo(MB::Sound.stereo(110.hz.saw, 165.hz.saw).flanger(:jet), 3000)
      expect(l).to eq(collect(110.hz.saw.flanger(:jet), 3000))
      expect(r).to eq(collect(165.hz.saw.flanger(:jet), 3000))
    end

    it 'offsets the right LFO by spread cycles' do
      # a quarter-cycle spread at 1 Hz: the right side equals a left side that started a quarter cycle on
      l, r = collect_stereo(110.hz.saw.flanger(1, spread: 0.25, shape: :sine), 4800)
      shifted = collect(110.hz.saw.flanger(1, phase: 0.25, shape: :sine), 4800)
      expect(r).to eq(shifted)
      expect(l).to eq(collect(110.hz.saw.flanger(1, shape: :sine), 4800))
    end

    it 'gives the same output at any buffer size with moving settings' do
      make = -> {
        MB::Sound.stereo(110.hz.saw, 165.hz.saw).flanger(:orbit, rate: 3, feedback: 0.3.hz.lfo.at(-0.8..0.8), mix: 0.2.hz.lfo.at(0.2..0.8))
      }
      a = collect_stereo(make.(), 9600, [1, 7, 128, 33])
      b = collect_stereo(make.(), 9600, 800)
      expect(a).to eq(b)
    end
  end

  describe 'rates' do
    it 'follows the tempo with musical lengths, through a tempo LFO' do
      node = 110.hz.saw.flanger(1.bar, feedback: 0) # (a loop's inner nodes aren't in #graph)
      lfo = node.graph.grep(MB::Sound::Tone).find(&:lfo?)
      expect(lfo.timeline).to be_a(MB::Sound::Sequence::TempoNode)
      expect(collect(lfo, 4000)).to eq(collect(1.bar.lfo.triangle, 4000))
    end

    it 'takes Hz, Pitches, Lengths per cycle, both shapes, and a sweep node' do
      expect(collect(110.hz.saw.flanger(0.5), 2000)).to eq(collect(110.hz.saw.flanger(0.5.hz), 2000))
      expect(collect(110.hz.saw.flanger(2.seconds), 2000)).to eq(collect(110.hz.saw.flanger(0.5), 2000))
      expect(collect(110.hz.saw.flanger(0.5, shape: :sine), 2000)).not_to eq(collect(110.hz.saw.flanger(0.5), 2000))
      env = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(-1, 1, 3000)])
      expect(collect(110.hz.saw.flanger(sweep: env, feedback: 0), 5000).length).to be < 5000
    end

    it 'holds the center at rate 0 or depth 0' do
      # (the held sine's delay is a float32 node, the number's a double: within -100 dB)
      a = collect(110.hz.saw.flanger(0, shape: :sine), 4000)
      b = collect(110.hz.saw.flanger(depth: 0), 4000)
      expect((a - b).abs.max).to be < 1e-5
    end
  end

  describe 'presets' do
    it 'has the presets in the library and renders each bounded' do
      expect(mod.preset_names).to include(:sweep, :jet, :sheen, :steel, :orbit, :tape_flange)
      expect(MB::Sound::L.fx.flanger.names).to include(:sweep, :jet)
      mod.preset_names.each do |name|
        out = 110.hz.saw.at(0.5).flanger(name)
        bufs = out.is_a?(MB::Sound::GraphNode::Channels) ? collect_stereo(out, 9600) : [collect(out, 9600)]
        bufs.each do |b|
          expect(b.isfinite.all?).to eq(true)
          expect(b.abs.max).to be_between(0.05, 6), "#{name}: peak #{b.abs.max}"
        end
      end
    end

    it 'lets options override a preset and a rate the default preset' do
      expect(collect(110.hz.saw.flanger(:jet, feedback: 0.2), 3000)).not_to eq(collect(110.hz.saw.flanger(:jet), 3000))
      expect(collect(110.hz.saw.flanger(0.3), 3000)).to eq(collect(110.hz.saw.flanger(:sweep, rate: 0.3), 3000))
    end
  end

  it 'mixes linearly: mix 0 is the dry input, mix 1 the wet alone' do
    expect(collect(110.hz.saw.flanger(mix: 0), 2000)).to eq(collect(110.hz.saw, 2000))
    out = collect(impulse.flanger(depth: 0, delay: 0.001, feedback: 0, mix: 1), 200)
    expect(out[0]).to eq(0)
    expect(out[48]).to eq(1)
  end

  it 'inverts the wet polarity with a negative wet level' do
    out = collect(impulse.flanger(depth: 0, delay: 0.001, feedback: 0, mix: 0.5, wet: -1), 200)
    expect([out[0], out[48]]).to eq([0.5, -0.5])
  end

  it 'rings out after its input ends, then ends' do
    out = collect(impulse.flanger(:jet), 200_000)
    expect(out.length).to be > 4000
    expect(out.length).to be < 200_000
    expect(out[-1000..].abs.max).to be < 1e-3
  end

  it 'loads back from Ruby and from a graph document with the same samples' do
    g = -> { 110.hz.saw.until(0.2).flanger(:steel, feedback: -0.6, spread: 0.25) }
    code = g.().to_ruby
    expect(code).to include('flanger(:steel, feedback: -0.6, spread: 0.25)')
    ref = RecipeHelpers.render(g.(), buffers: 20)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(RecipeHelpers.eval_recipe(code), buffers: 20))).to eq(0)
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g.()))
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(loaded, buffers: 20))).to eq(0)
  end

  it 'takes nodes for depth, feedback, mix, and the delay' do
    out = collect(110.hz.saw.flanger(depth: 0.1.hz.lfo.at(0..1), feedback: 0.2.hz.lfo.at(-0.9..0.9), mix: 0.3.constant,
      delay: 0.05.hz.lfo.at(0.001..0.003), range: 1.constant), 9600)
    expect(out.isfinite.all?).to eq(true)
    expect(out.abs.max).to be > 0.1
  end

  it 'rejects bad arguments with helpful messages' do
    expect { 110.hz.saw.flanger(feedbak: 0.5) }.to raise_error(ArgumentError, /feedbak.*feedback/)
    expect { 110.hz.saw.flanger(:jett) }.to raise_error(ArgumentError, /jet/)
    expect { 110.hz.saw.flanger(feedback: 0.99) }.to raise_error(ArgumentError, /0.95/)
    expect { 110.hz.saw.flanger(shape: :square) }.to raise_error(ArgumentError, /:sine or :triangle/)
    expect { 110.hz.saw.flanger(law: :log) }.to raise_error(ArgumentError, /:octaves or :linear/)
    expect { 110.hz.saw.flanger(delay: 1.ms, range: 1.ms..2.ms) }.to raise_error(ArgumentError, /range: of delay times/)
    expect { 110.hz.saw.flanger(sweep: 1.constant, spread: 0.5) }.to raise_error(ArgumentError, /spread/)
    expect { 110.hz.saw.flanger(0.5, rate: 1) }.to raise_error(ArgumentError, /once/)
    expect { 110.hz.saw.flanger(mix: 1.5) }.to raise_error(ArgumentError, /mix/)
    expect { 110.hz.saw.flanger(delay: -1.ms) }.to raise_error(ArgumentError, /positive/)
    expect { MB::Sound::GraphNode::Channels.new([1.constant, 2.constant, 3.constant]).flanger }.to raise_error(ArgumentError, /mono or stereo/)
  end
end
