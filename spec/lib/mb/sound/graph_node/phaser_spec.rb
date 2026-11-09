RSpec.describe(MB::Sound::GraphNode::Phaser, :aggregate_failures) do
  let(:klass) { MB::Sound::GraphNode::Phaser }

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

  # The magnitude response (dB) at the rfft bins of the impulse response of
  # +options+' phaser held at its center (depth 0), and the bin frequencies.
  def measured_response(length = 16384, **options)
    imp = Numo::SFloat.zeros(length)
    imp[0] = 1
    node = MB::Sound::ArrayInput.new(data: [imp]).phaser(**{ depth: 0 }.merge(options))
    ir = collect(node, length)
    spec = Numo::Pocketfft.rfft(Numo::DFloat.cast(ir))
    freqs = Numo::DFloat.new(spec.length).seq * (48000.0 / length)
    [freqs, 20 * Numo::NMath.log10(spec.abs + 1e-300)]
  end

  def analytic_db(freqs, **options)
    20 * Numo::NMath.log10(klass.response(freqs, **options).abs + 1e-300)
  end

  describe 'kernel' do
    let(:rng) { Random.new(17) }

    def noise(n, scale = 1.0, offset = 0.0)
      Numo::SFloat.cast(Array.new(n) { (rng.rand - 0.5) * scale + offset })
    end

    # Runs FastFilter.phaser and the mirror from the same state and expects
    # identical samples and states.
    def compare(n, x, sweep, center, range, depth, feedback, dry, wet, stages: 4)
      a = Numo::SFloat.zeros(n)
      b = Numo::SFloat.zeros(n)
      sa = Numo::DFloat.cast(noise(stages + 1, 0.01))
      sa[stages] = 795 # (the flush grid point lands inside the buffer)
      sb = sa.dup
      MB::Sound::FastFilter.phaser(a, x, sweep, center, range, depth, feedback, dry, wet, sa, 48000)
      klass.process_ruby(b, x, sweep, center, range, depth, feedback, dry, wet, sb, 48000)
      expect(a).to eq(b)
      expect(sa).to eq(sb)
      a
    end

    it 'matches the Ruby mirror with constant and moving settings at every stage count' do
      x = noise(1200)
      sweep = Numo::SFloat.cast(Numo::DFloat.linspace(-1, 1, 1200))
      [2, 4, 8, 12].each do |stages|
        compare(1200, x, sweep, 700.0, 4.0, 1.0, 0.6, 0.5, 0.5, stages: stages)
        compare(1200, x, 0.0, 300.0, 4.0, 1.0, -0.8, 1.0, -1.0, stages: stages)
        compare(1200, Numo::DFloat.cast(x), noise(1200, 2), noise(1200, 1000, 1500), noise(1200, 6, 3), noise(1200, 1, 0.5),
          noise(1200, 1.8), noise(1200), noise(1200), stages: stages)
      end
      compare(10, 0.25, 0.5, 1000.0, 2.0, 1.0, 0.0, 0.5, 0.5, stages: 6)
    end

    it 'matches the Ruby mirror for edge-case settings' do
      odd = Numo::SFloat.cast([Float::NAN, -1, 2, 0, 0.5, 1, Float::INFINITY, -Float::INFINITY] * 30)
      out = compare(odd.length, noise(odd.length), odd, odd * 30000, odd * 20, odd, odd, 0.5, 0.5, stages: 8)
      expect(out[8..].isfinite.to_a.count(0)).to be < odd.length # (NaN inputs give NaN samples, the rest stay finite)
    end

    it 'raises for bad arguments' do
      out = Numo::SFloat.zeros(4)
      st = Numo::DFloat.zeros(5)
      f = MB::Sound::FastFilter
      expect { f.phaser(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, Numo::DFloat.zeros(1), 48000) }.to raise_error(ArgumentError, /state/)
      expect { f.phaser(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, Numo::SFloat.zeros(5), 48000) }.to raise_error(ArgumentError, /state/)
      expect { f.phaser(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, st, 0) }.to raise_error(ArgumentError, /rate/)
      expect { f.phaser(out, Numo::SFloat.zeros(3), 0.0, 700, 4, 1, 0, 0.5, 0.5, st, 48000) }.to raise_error(ArgumentError, /length/)
      expect { f.phaser(Numo::DFloat.zeros(4), 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, st, 48000) }.to raise_error(ArgumentError, /output/)
    end
  end

  describe 'notches' do
    it 'puts notches at fc tan((2k + 1) pi / (2 stages)) for each stage count and center' do
      [[2, 1000.0], [4, 700.0], [6, 400.0], [12, 2000.0]].each do |stages, center|
        expected = klass.notch_frequencies(stages, center)
        expect(expected.length).to eq(stages / 2)

        # The analytic response is a deep minimum there
        mins = analytic_db(Numo::DFloat.cast(expected), stages: stages, frequency: center)
        expect(mins.max).to be < -100

        # The rendered impulse response matches the analytic response
        freqs, db = measured_response(stages: stages, center: center)
        want = analytic_db(freqs, stages: stages, frequency: center)
        audible = want.gt(-40).where
        expect((db[audible] - want[audible]).abs.max).to be < 0.01

        # and its deepest bins sit on the notches (within a bin)
        expected.each do |f|
          near = ((f - 40) / 2.93).round..((f + 40) / 2.93).round
          lowest = near.min_by { |i| db[i] }
          expect((freqs[lowest] - f).abs).to be <= 2.93
          expect(db[lowest]).to be < -25
        end
      end
    end

    it "puts four stages' notches at 0.414 and 2.414 times a low center" do
      n = klass.notch_frequencies(4, 100.0)
      expect(n[0]).to be_within(0.01).of(100 * Math.tan(Math::PI / 8))
      expect(n[1]).to be_within(0.05).of(100 * Math.tan(3 * Math::PI / 8))
    end

    it 'sweeps the notch frequency with the LFO across center * 2 ** (+-range / 2)' do
      # A static sweep at +1 is the center an octave and a half up (range 3)
      freqs, db = measured_response(stages: 4, center: 500.0, range: 3.0, sweep: 1.constant, depth: 1)
      want = analytic_db(freqs, stages: 4, frequency: 500.0 * 2**1.5)
      audible = want.gt(-40).where
      expect((db[audible] - want[audible]).abs.max).to be < 0.01
    end

    it 'takes a range of frequencies as the ends of the sweep' do
      node = 110.hz.saw.phaser(range: 200..3200)
      expect(node.instance_variable_get(:@center)).to be_within(1e-9).of(800)
      expect(node.instance_variable_get(:@range)).to be_within(1e-12).of(4)
    end
  end

  describe 'feedback' do
    it 'matches the zero-delay feedback analysis for both signs' do
      [0.7, -0.7, 0.95].each do |k|
        freqs, db = measured_response(32768, stages: 6, center: 900.0, feedback: k)
        want = analytic_db(freqs, stages: 6, frequency: 900.0, feedback: k)
        audible = want.gt(-40).where
        expect((db[audible] - want[audible]).abs.max).to be < 0.02
      end
    end

    it 'peaks at 1 / (1 - k) over the wet level, between the notches' do
      freqs = Numo::DFloat.linspace(20, 20000, 20000)
      peak = klass.response(freqs, stages: 4, frequency: 700.0, feedback: 0.8, dry: 0, wet: 1).abs.max
      expect(peak).to be_within(1e-3).of(1 / (1 - 0.8))
    end

    it 'stays stable at the feedback limit under fast full-range sweeps' do
      noise = MB::Sound.noise(seed: 5)
      node = noise.phaser(30, stages: 12, feedback: 0.95, range: 10, center: 1000)
      out = collect(node, 48000 * 3)
      expect(out.isfinite.all?).to eq(true)
      expect(out.abs.max).to be < 30
      # the second and third seconds aren't growing
      a = out[48000...96000].abs.max
      b = out[96000..].abs.max
      expect(b).to be < a * 1.5
    end

    it 'clamps feedback nodes to the limit and rejects numbers past it' do
      a = collect(110.hz.saw.phaser(feedback: 2.constant), 3000)
      b = collect(110.hz.saw.phaser(feedback: 0.95), 3000)
      expect(a).to eq(b)
      expect { 110.hz.saw.phaser(feedback: 0.96) }.to raise_error(ArgumentError, /feedback/)
      expect { 110.hz.saw.phaser(feedback: -1) }.to raise_error(ArgumentError, /feedback/)
    end
  end

  describe 'stereo' do
    it 'stays mono without spread and makes a mono input stereo with spread' do
      expect(110.hz.saw.phaser).to be_a(klass)
      out = 110.hz.saw.phaser(spread: 0.25)
      expect(out).to be_a(MB::Sound::GraphNode::Channels)
      expect(out.channel_count).to eq(2)
    end

    it "offsets the right side's LFO by spread cycles" do
      l, r = collect_stereo(110.hz.saw.phaser(2, spread: 0.5, stages: 6), 6000)
      right_alone = collect(110.hz.saw.phaser(2, phase: 0.5, stages: 6), 6000)
      left_alone = collect(110.hz.saw.phaser(2, stages: 6), 6000)
      expect(r).to eq(right_alone)
      expect(l).to eq(left_alone)
      expect(l).not_to eq(r)
    end

    it 'phases each side of a stereo input, with or without spread' do
      l, r = collect_stereo(MB::Sound.stereo(110.hz.saw, 165.hz.saw).phaser(:vintage), 3000)
      expect(l).to eq(collect(110.hz.saw.phaser(:vintage), 3000))
      expect(r).to eq(collect(165.hz.saw.phaser(:vintage), 3000))
    end

    it 'gives the same output at any buffer size with moving settings' do
      make = -> {
        MB::Sound.stereo(110.hz.saw, 165.hz.saw).phaser(:swirl, rate: 3, feedback: 0.3.hz.lfo.at(-0.8..0.8), mix: 0.2.hz.lfo.at(0.2..0.8),
          center: 0.1.hz.lfo.at(300..1500))
      }
      a = collect_stereo(make.(), 9600, [1, 7, 128, 33])
      b = collect_stereo(make.(), 9600, 800)
      expect(a).to eq(b)
    end
  end

  describe 'rates' do
    it 'follows the tempo with musical lengths, through a tempo LFO' do
      node = 110.hz.saw.phaser(1.bar)
      lfo = node.graph.grep(MB::Sound::Tone).find(&:lfo?)
      expect(lfo.timeline).to be_a(MB::Sound::Sequence::TempoNode)
      expect(collect(node.sources[:sweep], 4000)).to eq(collect(1.bar.lfo.sine, 4000))

      # one cycle per bar: a quarter bar in, the sine is at its top
      quarter = (MB::Sound::Sequence.current_transport.seconds_of(1) * 48000 / 4).round
      sweep = collect(110.hz.saw.phaser(1.bar).sources[:sweep], quarter + 1)
      expect(sweep[quarter]).to be_within(1e-4).of(1)
    end

    it 'keeps following the tempo when it changes mid-render' do
      transport = MB::Sound::Sequence.current_transport
      old_bpm = transport.bpm
      begin
        MB::Sound.bpm(120)
        MB::Sound.rewind
        sweep = 110.hz.saw.phaser(1.bar).sources[:sweep]
        bufs = Array.new(48) { sweep.sample(1000).dup } # one second: half a bar at 120 BPM
        MB::Sound.bpm(60)
        bufs += Array.new(300) { sweep.sample(1000).dup }
        x = SpecBuffers.join(bufs).to_a
        crossings = (1...x.length).select { |i| (x[i - 1] < 0) != (x[i] < 0) }
        # half cycles of 48000 samples (2 s bars), then 96000 (4 s bars)
        expect(crossings[0]).to be_within(2).of(48000)
        expect(crossings.each_cons(2).map { |a, b| b - a }).to all(be_within(2).of(96000))
        expect(crossings.length).to eq(4)
      ensure
        MB::Sound.bpm(old_bpm)
        MB::Sound.rewind
      end
    end

    it 'takes Hz, Pitches, Lengths per cycle, triangle shapes, and a sweep node' do
      expect(collect(110.hz.saw.phaser(0.5), 2000)).to eq(collect(110.hz.saw.phaser(0.5.hz), 2000))
      expect(collect(110.hz.saw.phaser(2.seconds), 2000)).to eq(collect(110.hz.saw.phaser(0.5), 2000))
      expect(collect(110.hz.saw.phaser(0.5, shape: :triangle), 2000)).not_to eq(collect(110.hz.saw.phaser(0.5), 2000))

      env = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(-1, 1, 3000)])
      swept = collect(110.hz.saw.phaser(sweep: env), 5000)
      expect(swept.length).to eq(3000)
    end

    it 'holds the center at rate 0' do
      a = collect(110.hz.saw.phaser(0), 2000)
      b = collect(110.hz.saw.phaser(depth: 0), 2000)
      expect(a).to eq(b)
    end
  end

  describe 'presets' do
    it 'has the presets in the library and renders each bounded' do
      expect(klass.preset_names).to include(:vintage, :swirl, :ripple, :deep12, :jet)
      expect(MB::Sound::Library.index.lookup(:phaser, :jet, note: false)).not_to be_nil
      klass.preset_names.each do |name|
        out = 110.hz.saw.at(0.5).phaser(name)
        bufs = out.is_a?(MB::Sound::GraphNode::Channels) ? collect_stereo(out, 9600) : [collect(out, 9600)]
        bufs.each do |b|
          expect(b.isfinite.all?).to eq(true)
          expect(b.abs.max).to be_between(0.05, 4), "#{name}: peak #{b.abs.max}"
        end
      end
    end

    it 'lets options override a preset and a rate the default preset' do
      jet = klass.preset_settings(:jet)
      node = 110.hz.saw.phaser(:jet, stages: 4)
      expect(node.stages).to eq(4)
      expect(110.hz.saw.phaser(:jet).stages).to eq(jet[:stages])
      expect(110.hz.saw.phaser(3).stages).to eq(klass.preset_settings(:vintage)[:stages])
    end
  end

  it 'mixes linearly: mix 0 is the dry input, mix 1 the chain alone' do
    dry = collect(120.hz.saw, 6000)
    expect(collect(120.hz.saw.phaser(mix: 0), 6000)).to eq(dry)
    wet = collect(120.hz.saw.phaser(mix: 1, depth: 0), 6000)
    # The chain alone is an allpass: the same power per harmonic once it has
    # settled (ten whole periods of the 400-sample saw)
    expect(Math.sqrt((wet[2000..] ** 2).mean)).to be_within(0.002).of(Math.sqrt((dry[2000..] ** 2).mean))
  end

  it 'inverts the wet polarity with a negative wet level' do
    a = collect(110.hz.saw.phaser(depth: 0, wet: -1), 2000)
    b = collect(110.hz.saw.phaser(depth: 0, wet: 1), 2000)
    dry = collect(110.hz.saw, 2000) * 0.5
    expect((a + b - dry * 2).abs.max).to be < 1e-5
  end

  it 'ends when its input or a parameter node ends' do
    input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(1000)])
    expect(collect(input.phaser, 5000).length).to eq(1000)
    depth = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(300)])
    expect(collect(110.hz.saw.phaser(depth: depth), 5000).length).to eq(300)
  end

  it 'adopts a rebuilt phaser of the same stage count' do
    old = 110.hz.saw.phaser
    collect(old, 1000)
    state = old.instance_variable_get(:@state).dup
    same = 110.hz.saw.phaser
    same.carry_adopt(old)
    expect(same.instance_variable_get(:@state)).to eq(state)
    other = 110.hz.saw.phaser(stages: 6)
    other.carry_adopt(same)
    expect(other.instance_variable_get(:@state)).to eq(Numo::DFloat.zeros(7))
  end

  it 'rejects bad arguments with helpful messages' do
    expect { 110.hz.saw.phaser(stages: 5) }.to raise_error(ArgumentError, /even/)
    expect { 110.hz.saw.phaser(stages: 14) }.to raise_error(ArgumentError, /even/)
    expect { 110.hz.saw.phaser(stage: 4) }.to raise_error(ArgumentError, /did you mean :stages/)
    expect { 110.hz.saw.phaser(:nope) }.to raise_error(ArgumentError, /phaser preset/)
    expect { 110.hz.saw.phaser(range: 200..3000, center: 500) }.to raise_error(ArgumentError, /range/)
    expect { 110.hz.saw.phaser(sweep: 1.constant, spread: 0.5) }.to raise_error(ArgumentError, /spread/)
    expect { 110.hz.saw.phaser(shape: :square) }.to raise_error(ArgumentError, /shape/)
    expect { 110.hz.saw.phaser(-1) }.to raise_error(ArgumentError, /rate/)
    expect { 110.hz.saw.phaser(2, rate: 3) }.to raise_error(ArgumentError, /rate/)
    expect { 110.hz.saw.phaser(mix: 1.5) }.to raise_error(ArgumentError, /mix/)
  end

  it 'prints itself back as Ruby and describes itself' do
    node = 110.hz.saw.phaser(:jet, feedback: 0.6)
    expect(node.to_ruby).to include('phaser(:jet, feedback: 0.6)')
    expect(node.to_s).to eq('Phaser 8 stages around 1000.0 Hz, feedback 0.6')
    stereo = 110.hz.saw.phaser(1.bar, spread: 0.25)
    expect(stereo.to_ruby).to include('phaser(1.bar, spread: 0.25)')
  end
end
