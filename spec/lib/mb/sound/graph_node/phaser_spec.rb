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
      [2, 4, 8, 12, 32].each do |stages|
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
      [[2, 1000.0], [4, 700.0], [6, 400.0], [12, 2000.0], [32, 2000.0]].each do |stages, center|
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

    it 'stays stable at 32 stages at the feedback limit (effects-3)' do
      node = MB::Sound.noise(seed: 6).phaser(30, stages: 32, feedback: 0.95, range: 10, center: 600)
      out = collect(node, 48000 * 3)
      expect(out.isfinite.all?).to eq(true)
      expect(out.abs.max).to be < 30
      expect(out[96000..].abs.max).to be < out[48000...96000].abs.max * 1.5
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
      node = 110.hz.saw.phaser(:jet, stages: 4, above: nil)
      expect(node.stages).to eq(4)
      expect(110.hz.saw.phaser(:jet, above: nil).stages).to eq(jet[:stages])
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
    expect { 110.hz.saw.phaser(stages: 34) }.to raise_error(ArgumentError, /even/)
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
    node = 110.hz.saw.phaser(:jet, feedback: 0.6, above: nil)
    expect(node.to_ruby).to include('phaser(:jet, feedback: 0.6, above: nil)')
    expect(node.to_s).to eq('Phaser 8 stages around 1000.0 Hz, feedback 0.6')
    stereo = 110.hz.saw.phaser(1.bar, spread: 0.25)
    expect(stereo.to_ruby).to include('phaser(1.bar, spread: 0.25)')
  end

  describe 'effects-3: above:, amount:, direction:' do
    it 'keeps the lows dry below above: (a Linkwitz-Riley split), so a notch there leaves a kick alone' do
      # four stages at 145 Hz notch 60 Hz (0.414 fc) and 350 Hz
      plain = collect(60.hz.sine.phaser(stages: 4, center: 145, depth: 0), 48000)
      split = collect(60.hz.sine.phaser(stages: 4, center: 145, depth: 0, above: 400), 48000)
      expect(plain[24000..].abs.max).to be < 0.05
      expect(split[24000..].abs.max).to be_within(0.03).of(1) # (the low band through the split's allpass)
      # well above the split the phaser works as without it
      hi_plain = collect(3000.hz.sine.phaser(:jet, depth: 0), 48000)[24000..].abs.max
      hi_split = collect(3000.hz.sine.phaser(:jet, depth: 0, above: 150), 48000)[24000..].abs.max
      expect(hi_split).to be_within(0.02 * hi_plain).of(hi_plain)
      # a mono input with spread comes back stereo; a rate positional too
      st = 110.hz.saw.phaser(:swirl, above: 150)
      expect(st).to be_a(MB::Sound::GraphNode::Channels)
      expect(110.hz.saw.phaser(2, above: 150.hz)).to be_a(MB::Sound::GraphNode::Mixer)
      expect { 110.hz.saw.phaser(above: 30000) }.to raise_error(ArgumentError, /above/)
    end

    it 'ends with a finite input and gives the same output at any buffer size with above:' do
      file = 'spec/test_data/arp_a7.flac'
      make = -> { MB::Sound.file_input(file).phaser(:swirl, above: 200) }
      a = make.()
      la, ra = collect_stereo(a, 48000, 800)
      close_inputs(a)
      b = make.()
      lb, rb = collect_stereo(b, 48000, [1, 7, 128, 33, 367])
      close_inputs(b)
      expect(la.length).to be < 48000 # (it ended)
      expect(lb).to eq(la)
      expect(rb).to eq(ra)
    end

    it 'turns one amount: from light (0) to extreme (1), 0.5 the preset as it is' do
      ref = collect(110.hz.saw.phaser(:swirl, spread: 0), 9600)
      expect(collect(110.hz.saw.phaser(:swirl, spread: 0, amount: 0.5), 9600)).to eq(ref)
      s = klass.amount_settings(klass.preset_settings(:swirl).merge(amount: 1))
      expect(s.slice(:depth, :mix, :stages)).to eq(depth: 1.0, mix: 0.5, stages: 12)
      expect(s[:feedback]).to be_within(1e-12).of(klass::AMOUNT_FEEDBACK)
      s = klass.amount_settings(klass.preset_settings(:swirl).merge(amount: 0))
      expect(s[:depth]).to be_within(1e-12).of(0.25)
      expect(s[:mix]).to be_within(1e-12).of(0.15)
      expect(s[:feedback]).to eq(0)
      expect(s[:stages]).to eq(4) # (6 halved, rounded to even)
      expect(klass.amount_settings(klass.preset_settings(:deep12).merge(amount: 1))[:stages]).to eq(24)
      expect(klass.amount_settings(klass.preset_settings(:jet).merge(amount: 1, feedback: -0.4))[:feedback]).to be_within(1e-12).of(-klass::AMOUNT_FEEDBACK)
      # a node moves depth, mix, and feedback (stages stay)
      a = collect_stereo(110.hz.saw.phaser(:swirl, amount: 0.3.constant, stages: 4), 9600)
      b = collect_stereo(110.hz.saw.phaser(:swirl, amount: 0.3), 9600)
      2.times { |c| expect((a[c] - b[c]).abs.max).to be < 1e-5 }
      expect { 110.hz.saw.phaser(amount: 1.2) }.to raise_error(ArgumentError, /amount/)
    end

    it 'makes a barber pole with direction:, whose crossfaded chains sum to one phaser where they agree' do
      # held at the center (depth 0) every chain is the same phaser, and the windows sum to 1
      ref = collect(110.hz.saw.phaser(:jet, depth: 0), 9600)
      pole = collect(110.hz.saw.phaser(:jet, depth: 0, direction: :up), 9600)
      expect((pole - ref).abs.max).to be < 1e-4
      up = collect(110.hz.saw.at(0.5).phaser(:barberpole), 48000)
      down = collect(110.hz.saw.at(0.5).phaser(:barberpole, direction: :down), 48000)
      [up, down].each { |b| expect(b.isfinite.all?).to eq(true); expect(b.abs.max).to be_between(0.05, 4) }
      expect(up).not_to eq(down)
      l, r = collect_stereo(110.hz.saw.phaser(:barberpole, spread: 0.5), 9600)
      expect(l).not_to eq(r)
      expect { 110.hz.saw.phaser(direction: :sideways) }.to raise_error(ArgumentError, /direction/)
      expect { 110.hz.saw.phaser(direction: :up, sweep: 0.constant) }.to raise_error(ArgumentError, /sweep/)
    end

    it 'climbs: the notch of a held-tone barber pole moves up through each chain\'s pass' do
      # a 1 kHz sine through :barberpole without feedback: the level dips each
      # time a notch crosses 1 kHz; :up and :down cross at the same times,
      # mirrored, so their level curves are each other's reverse in time
      opts = { rate: 1, feedback: 0, stages: 2, range: 4, center: 1000 }
      up = collect(1000.hz.sine.phaser(:barberpole, **opts), 48000)
      down = collect(1000.hz.sine.phaser(:barberpole, direction: :down, **opts), 48000)
      env = ->(x) { (0...48).map { |k| x[(k * 1000)...((k + 1) * 1000)].abs.max } }
      eu = env.(up)
      ed = env.(down)
      expect(eu.max - eu.min).to be > 0.1
      # (one cycle: 48 blocks; the down curve runs the up curve backward)
      expect(eu[1...47].zip(ed[1...47].reverse).map { |a, b| (a - b).abs }.max).to be < 0.05
    end
  end

  describe 'effects-4: :jet above 150 Hz, direction: as a knob' do
    it 'keeps the lows of :jet dry below 150 Hz unless above: nil' do
      expect(collect(110.hz.saw.phaser(:jet), 9600)).to eq(collect(110.hz.saw.phaser(:jet, above: 150), 9600))
      expect(110.hz.saw.phaser(:jet)).to be_a(MB::Sound::GraphNode::Mixer)
      expect(110.hz.saw.phaser(:jet, above: nil)).to be_a(klass)
      expect(collect(110.hz.saw.phaser(:jet, above: 300), 9600)).not_to eq(collect(110.hz.saw.phaser(:jet), 9600))
    end

    it 'scales the barber pole\'s speed by the size of a numeric direction:, its sign the way' do
      opts = { stages: 4, feedback: 0.3 }
      bp = ->(**o) { collect(110.hz.saw.phaser(:barberpole, **opts, **o), 24000) }
      expect(bp.(direction: 1)).to eq(bp.())
      expect(bp.(direction: -1)).to eq(bp.(direction: :down))
      expect(bp.(direction: 2)).to eq(bp.(rate: 0.2))
      expect(bp.(direction: -0.5)).to eq(bp.(rate: 0.05, direction: :down))
      # a musical rate stays a (shorter) musical length, locked to the timeline
      expect(bp.(rate: 1.bar, direction: 4)).to eq(bp.(rate: 1.n4))
      held = bp.(direction: 0)
      expect(held.isfinite.all?).to eq(true)
      expect(held).to eq(bp.(rate: 0))
    end

    it 'takes a node direction: that turns the notches around live without a jump' do
      opts = { rate: 1, feedback: 0, stages: 2, range: 4, center: 1000 }
      # a constant node plays like the number (float32 node values: within rounding)
      a = collect(1000.hz.sine.phaser(:barberpole, direction: 1.5.constant, **opts), 24000)
      b = collect(1000.hz.sine.phaser(:barberpole, direction: 1.5, **opts), 24000)
      expect((a - b).abs.max).to be < 1e-3
      # up for half a second, then down: the second half's dips run the first's backward
      turn = 1.0.constant.until(0.5).and_then((-1.0).constant)
      x = collect(1000.hz.sine.phaser(:barberpole, direction: turn, **opts), 48000)
      expect(x.isfinite.all?).to eq(true)
      steady = collect(1000.hz.sine.phaser(:barberpole, direction: 1, **opts), 48000)
      step = ->(v) { (v[1..] - v[0...-1]).abs.max }
      expect(step.(x)).to be < step.(steady) * 1.05 # (no click at the turn)
      env = ->(v, r) { r.map { |k| v[(k * 1000)...((k + 1) * 1000)].abs.max } }
      first = env.(x, 1...24) # (block 0: the chains starting up)
      second = env.(x, 24...47)
      expect(first.reverse.zip(second).map { |p, q| (p - q).abs }.max).to be < 0.002
      expect { 110.hz.saw.phaser(direction: Float::NAN) }.to raise_error(ArgumentError, /finite/)
      expect(110.hz.saw.phaser(:barberpole, direction: -2).to_ruby).to include('phaser(:barberpole, direction: -2)')
    end

    it 'leans the feedback to one half of the sweep with lean: (his hypothesis)' do
      # the feedback's scale: 1 while the LFO rises (its first quarter cycle and last), 1 - |lean| while it falls
      scale = klass.lean_feedback(1.0, 0.5, 1, 0, 48000)
      v = collect(scale, 48000)
      expect(v[0...9000].to_a.uniq).to eq([1.0])
      expect(v[15000...33000].to_a.uniq).to eq([0.5])
      expect(v[39000..].to_a.uniq).to eq([1.0])
      expect(v[12000 + 2400 - 1]).to be_within(1e-6).of(0.5) # (the turn glides over LEAN_SMOOTH, 2400 samples)
      down = collect(klass.lean_feedback(0.8, -1, 1, 0, 48000), 48000)
      expect(down[0...9000].to_a.uniq).to eq([0.0])
      expect(down[15000...33000].to_a.uniq.length).to eq(1)
      expect(down[20000]).to be_within(1e-6).of(0.8)
      # rising first: lean 1 plays the full feedback there, lean -1 none (as feedback 0)
      opts = { rate: 1, above: nil, shape: :triangle }
      full = collect(110.hz.saw.phaser(:jet, **opts), 9000)
      none = collect(110.hz.saw.phaser(:jet, **opts, feedback: 0), 9000)
      expect((collect(110.hz.saw.phaser(:jet, **opts, lean: 1), 9000) - full).abs.max).to be < 1e-4
      expect((collect(110.hz.saw.phaser(:jet, **opts, lean: -1), 9000) - none).abs.max).to be < 1e-4
      expect(collect(110.hz.saw.phaser(:jet, **opts, lean: 0), 9000)).to eq(full)
      # a moving lean node, read once per sample (while rising: 1 for a positive lean, 1 + lean for a negative one)
      lv = collect(3.hz.lfo, 9000)
      v = collect(klass.lean_feedback(1.0, 3.hz.lfo, 1, 0, 48000), 9000)
      want = lv.to_a.map { |l| l < 0 ? 1 + l : 1.0 }
      expect((v - Numo::SFloat.cast(want)).abs.max).to be < 1e-6
      # a node lean, stereo, and a feedback node
      a = collect_stereo(110.hz.saw.phaser(:swirl, lean: -0.7.constant), 24000)
      b = collect_stereo(110.hz.saw.phaser(:swirl, lean: -0.7), 24000)
      2.times { |c| expect((a[c] - b[c]).abs.max).to be < 1e-4 }
      expect(collect(110.hz.saw.phaser(:jet, **opts, lean: -1, feedback: 0.3.constant), 9600).isfinite.all?).to eq(true)
      expect { 110.hz.saw.phaser(lean: 1.5) }.to raise_error(ArgumentError, /lean/)
      expect { 110.hz.saw.phaser(lean: 1, sweep: 0.constant) }.to raise_error(ArgumentError, /sweep/)
      expect { 110.hz.saw.phaser(:barberpole, lean: 1) }.to raise_error(ArgumentError, /barber/)
      expect(110.hz.saw.phaser(:jet, lean: -1).to_ruby).to include('phaser(:jet, lean: -1)')
    end
  end

  describe 'effects-4: oscillate: (self-oscillation on one mode)' do
    let(:rng) { Random.new(23) }

    def noise(n, scale = 1.0, offset = 0.0)
      Numo::SFloat.cast(Array.new(n) { (rng.rand - 0.5) * scale + offset })
    end

    # The C kernel and its Ruby mirror on the same arguments: identical samples and states.
    def compare_osc(n, x, sweep, center, range, depth, feedback, dry, wet, stages: 4, mode: 0, state: nil, level: 1.0, tuned: false)
      a = Numo::SFloat.zeros(n)
      b = Numo::SFloat.zeros(n)
      sa = state || Numo::DFloat.zeros(stages + 5)
      sa[stages + 3] = 795 # (the flush grid point inside the buffer)
      sb = sa.dup
      MB::Sound::FastFilter.phaser_osc(a, x, sweep, center, range, depth, feedback, dry, wet, sa, 48000, mode, level, tuned)
      klass.process_osc_ruby(b, x, sweep, center, range, depth, feedback, dry, wet, sb, 48000, mode, level, tuned)
      expect(a).to eq(b)
      expect(sa).to eq(sb)
      a
    end

    # The strongest spectral line of +x+ in Hz, and the next strongest away from it in dB below it.
    def lines(x)
      w = x.length
      win = Numo::DFloat.new(w).seq.map { |i| 0.5 - 0.5 * Math.cos(2 * Math::PI * i / w) }
      s = Numo::Pocketfft.rfft(Numo::DFloat.cast(x) * win).abs
      i = s.max_index
      j = (1...s.length).reject { |k| (k - i).abs < [i * 0.05, 3].max }.max_by { |k| s[k] }
      [i * 48000.0 / w, 20 * Math.log10(s[j] / s[i])]
    end

    it 'matches the Ruby mirror (silence, a kick, moving settings, a feedback sweep past 1, every mode and sign)' do
      sweep = Numo::SFloat.cast(Numo::DFloat.linspace(-1, 1, 1200))
      fb = Numo::SFloat.cast(Numo::DFloat.linspace(-1.3, 1.3, 1200))
      [2, 4, 8, 32].each do |stages|
        [0, 1, 40].each do |mode|
          compare_osc(1200, 0.0, 0.0, 1000.0, 4.0, 0.0, -1.1, 0.5, 0.5, stages: stages, mode: mode)
          compare_osc(1200, noise(1200), sweep, 700.0, 4.0, 1.0, fb, 0.5, 0.5, stages: stages, mode: mode)
          compare_osc(1200, noise(1200, 2), noise(1200, 2), noise(1200, 1000, 1500), noise(1200, 6, 3), noise(1200, 1, 0.5),
            noise(1200, 2.6), noise(1200), noise(1200), stages: stages, mode: mode, state: Numo::DFloat.cast(noise(stages + 5, 0.2)))
        end
        # effects-5: fractional and moving modes, levels, the tuned center
        compare_osc(1200, 0.0, 0.0, 900.0, 4.0, 0.0, -1.1, 0.5, 0.5, stages: stages, mode: 1.5, level: 14.0, tuned: true)
        compare_osc(1200, noise(1200), sweep, 700.0, 4.0, 1.0, fb, 0.5, 0.5, stages: stages, mode: noise(1200, 8, 2), level: noise(1200, 4, 2))
        compare_osc(1200, noise(1200, 2), sweep, noise(1200, 3000, 1500), 3.0, 1.0, fb, 0.5, 0.5, stages: stages, mode: noise(1200, 30, 10),
          level: noise(1200, 0.5, 0.3), tuned: true)
      end
      odd = Numo::SFloat.cast([Float::NAN, -1, 2, 0, 0.5, 1, Float::INFINITY, -Float::INFINITY] * 30)
      compare_osc(odd.length, noise(odd.length), odd, odd * 30000, odd * 20, odd, odd, 0.5, 0.5, stages: 8, mode: 2)
      compare_osc(odd.length, noise(odd.length), odd, odd * 30000, odd * 20, odd, odd, 0.5, 0.5, stages: 8, mode: odd * 3, level: odd * 1e5, tuned: true)
      f = MB::Sound::FastFilter
      out = Numo::SFloat.zeros(4)
      expect { f.phaser_osc(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, Numo::DFloat.zeros(6), 48000, 0, 1, false) }.to raise_error(ArgumentError, /state/)
      expect { f.phaser_osc(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, Numo::DFloat.zeros(9), 48000, -1, 1, false) }.to raise_error(ArgumentError, /mode/)
      expect { f.phaser_osc(out, 0.0, 0.0, 700, 4, 1, 0, 0.5, 0.5, Numo::DFloat.zeros(9), 48000, 0) }.to raise_error(ArgumentError, /arguments/)
    end

    it 'whistles on one line at the mode frequency from silence, at a level the loop sets, only past |feedback| 1' do
      [[4, 0, -1.1], [8, 2, 1.1], [32, 7, -1.1], [12, 3, -1.02]].each do |stages, mode, fb|
        x = collect(0.constant.phaser(stages: stages, center: 1000, depth: 0, feedback: fb, oscillate: mode, mix: 1), 48000 * 3)
        expect(x.isfinite.all?).to eq(true)
        hz, next_db = lines(x[-32768..])
        want = klass.mode_frequency(stages, 1000, mode: mode, feedback: fb)
        expect(hz).to be_within(48000.0 / 32768).of(want), "#{stages} stages, mode #{mode}"
        expect(next_db).to be < -40 # (one line: the saturator's third harmonic about -50 dB)
        expect(x[-48000..].abs.max).to be_between(0.2, 1.1)
      end
      # the level grows with the loop gain past 1; at 1 and below, silence stays silent
      peak = ->(fb) { collect(0.constant.phaser(center: 1000, depth: 0, feedback: fb, oscillate: 0, mix: 1), 48000 * 2)[-24000..].abs.max }
      expect(peak.(-1.05)).to be < peak.(-1.25)
      expect(peak.(-1.0)).to eq(0)
      expect(peak.(0.9)).to eq(0)
    end

    it 'stays bounded with full-scale input and a feedback node swept past 1, and equal at any buffer size' do
      mk = -> { 110.hz.saw.phaser(:jet, above: nil, rate: 3, stages: 8, feedback: 0.5.hz.lfo.at(-1.25..1.25), oscillate: 1) }
      a = collect(mk.(), 96000)
      b = collect(mk.(), 96000, [1, 7, 128, 33, 367])
      expect(b).to eq(a)
      expect(a.isfinite.all?).to eq(true)
      expect(a.abs.max).to be < 4
      loud = collect(MB::Sound.noise(seed: 3).phaser(stages: 32, feedback: -1.25, oscillate: 7, rate: 5, mix: 0.5), 48000)
      expect(loud.isfinite.all?).to eq(true)
      expect(loud.abs.max).to be < 4
    end

    it 'leaves the linear loop as it was, carries only to the same loop, and checks its settings' do
      ref = collect(110.hz.saw.phaser(:vintage, feedback: 0.9), 9600)
      expect(collect(110.hz.saw.phaser(:vintage, feedback: 0.9, oscillate: false), 9600)).to eq(ref)
      osc = 110.hz.saw.phaser(feedback: -1.1, oscillate: true)
      expect(osc.oscillate).to eq(0)
      expect(osc.to_s).to include('oscillating on mode 0')
      expect(osc.to_ruby).to include('phaser(feedback: -1.1, oscillate: true)')
      plain = 110.hz.saw.phaser(feedback: -0.5)
      collect(plain, 800)
      fresh = 110.hz.saw.phaser(feedback: -1.1, oscillate: 0)
      fresh.carry_adopt(plain) # (another loop: starts fresh)
      expect(fresh.instance_variable_get(:@state).length).to eq(9)
      expect { 110.hz.saw.phaser(feedback: -1.1) }.to raise_error(ArgumentError, /oscillate/)
      expect { 110.hz.saw.phaser(feedback: -1.3, oscillate: 0) }.to raise_error(ArgumentError, /feedback/)
      expect { 110.hz.saw.phaser(oscillate: -1) }.to raise_error(ArgumentError, /oscillate/)
      expect { 110.hz.saw.phaser(:barberpole, oscillate: [0, 1]) }.to raise_error(ArgumentError, /barber/)
    end

    it 'gives mode frequencies and their inverse for fitting a measured whistle' do
      expect(klass.mode_frequency(4, 1000)).to be_within(1e-9).of(klass.notch_frequencies(4, 1000)[0])
      expect(klass.mode_frequency(8, 1000, mode: 3)).to be_within(1e-9).of(klass.notch_frequencies(8, 1000)[3])
      expect(klass.mode_frequency(4, 1000, mode: 9)).to eq(klass.mode_frequency(4, 1000, mode: 1)) # (past the last: the last)
      lo = klass.mode_center(32, 250, mode: 7)
      hi = klass.mode_center(32, 2110, mode: 7)
      expect(klass.mode_frequency(32, lo, mode: 7)).to be_within(1e-6).of(250)
      expect(klass.mode_frequency(32, hi, mode: 7)).to be_within(1e-6).of(2110)
      expect(klass.mode_frequency(8, 1000, mode: 0, feedback: 1)).to be_within(1e-6).of(Math.atan(Math.tan(Math::PI / 48) * Math.tan(Math::PI / 8)) * 48000 / Math::PI)
    end
  end

  describe 'effects-5: the self-oscillating loop generalized, lanes' do
    # The strongest spectral line of +x+ in Hz, and the next strongest away from it in dB below it.
    def lines(x)
      w = x.length
      win = Numo::DFloat.new(w).seq.map { |i| 0.5 - 0.5 * Math.cos(2 * Math::PI * i / w) }
      s = Numo::Pocketfft.rfft(Numo::DFloat.cast(x) * win).abs
      i = s.max_index
      j = (1...s.length).reject { |k| (k - i).abs < [i * 0.05, 3].max }.max_by { |k| s[k] }
      [i * 48000.0 / w, 20 * Math.log10(s[j] / s[i])]
    end

    # The frequencies of the +count+ strongest lines of +x+, lowest first.
    def top_lines(x, count)
      w = x.length
      win = Numo::DFloat.new(w).seq.map { |i| 0.5 - 0.5 * Math.cos(2 * Math::PI * i / w) }
      s = Numo::Pocketfft.rfft(Numo::DFloat.cast(x) * win).abs
      Array.new(count) {
        i = s.max_index
        s[[i - 20, 0].max..(i + 20)] = 0
        i * 48000.0 / w
      }.sort
    end

    let(:whistle) { { stages: 32, depth: 0.51, feedback: -1.02, center: 797.6, range: 6.0, oscillate: 7, mix: 1 } }

    it "scales the whistle with level: (the .acd converter's in at 1/14, out x 14); level 1 is the effects-4 loop" do
      a = collect((110.hz.saw.at(0.3) * (1 / 14.0)).phaser(0.2, **whistle) * 14.0, 48000 * 2)
      b = collect(110.hz.saw.at(0.3).phaser(0.2, **whistle, level: 14), 48000 * 2)
      expect((a - b).abs.max).to be < 1e-5 * a.abs.max
      expect(collect(110.hz.saw.phaser(0.2, **whistle, level: 1), 9600)).to eq(collect(110.hz.saw.phaser(0.2, **whistle), 9600))
      peak = ->(level) { collect(0.constant.phaser(center: 1000, depth: 0, feedback: -1.1, oscillate: 0, mix: 1, level: level), 48000 * 2)[-24000..].abs.max }
      expect(peak.(0.5) / peak.(1)).to be_within(0.01).of(0.5)
      expect(peak.(-6.db)).to be_within(1e-6).of(peak.(10**(-6 / 20.0)))
      expect(peak.(0.2.hz.lfo.at(0.5..1.5))).to be_between(0.2, 1.1) # (a node)
    end

    it 'tunes the whistle with pitch: (Hz, a node, or the ends of its sweep) at every stage count and sign' do
      [[2, 0, -1.1], [4, 1, -1.1], [8, 2, 1.1], [16, 5, -1.05], [32, 7, -1.05], [32, 3, 1.1]].each do |stages, mode, fb|
        x = collect(0.constant.phaser(stages: stages, depth: 0, feedback: fb, oscillate: mode, pitch: 900, mix: 1), 48000 * 3)
        hz, next_db = lines(x[-32768..])
        expect(hz).to be_within(48000.0 / 32768).of(900), "#{stages} stages, mode #{mode}, feedback #{fb}"
        expect(next_db).to be < -40
      end
      step = 600.constant.until(2).and_then(900.constant)
      x = collect(0.constant.phaser(stages: 8, depth: 0, feedback: -1.1, oscillate: 2, pitch: step, mix: 1), 48000 * 4)
      expect(lines(x[48000...96000])[0]).to be_within(3).of(600)
      expect(lines(x[-48000..])[0]).to be_within(3).of(900)

      node = 110.hz.saw.phaser(0.2, stages: 32, oscillate: 7, feedback: -1.05, pitch: 250..2110)
      c = node.instance_variable_get(:@center)
      oct = node.instance_variable_get(:@range)
      fc = klass.mode_center(32, c, mode: 7)
      expect(klass.mode_frequency(32, fc * 2**(-oct / 2), mode: 7)).to be_within(1e-6).of(250)
      expect(klass.mode_frequency(32, fc * 2**(oct / 2), mode: 7)).to be_within(1e-6).of(2110)
      expect(node.tuned).to eq(true)
      expect { 110.hz.saw.phaser(oscillate: 0, feedback: -1.1, pitch: 500, center: 300) }.to raise_error(ArgumentError, /pitch/)
      expect { 110.hz.saw.phaser(pitch: 500) }.to raise_error(ArgumentError, /oscillate/)
      expect { 110.hz.saw.phaser(oscillate: 0, pitch: 500, range: 200..800) }.to raise_error(ArgumentError, /pitch/)
    end

    it 'moves between modes with a mode node, kicking each new mode once from silence, and never ticks between them' do
      modes = (0..3).map { |m| klass.mode_frequency(8, 1000, mode: m) }
      mode = 1.constant.until(2).and_then(2.constant)
      x = collect(0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: -1.1, oscillate: mode, mix: 1), 48000 * 4)
      expect(lines(x[48000...96000])[0]).to be_within(3).of(modes[1])
      expect(lines(x[-48000..])[0]).to be_within(3).of(modes[2])
      # (between two modes, and at 2 stages with positive feedback, the loop
      # can't sustain itself: one kick, then silence, not a tick train)
      x = collect(0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: -1.1, oscillate: 1.5, mix: 1), 48000 * 2)
      expect(x[24000..].abs.max).to be < 1e-9
      x = collect(0.constant.phaser(stages: 2, depth: 0, feedback: 1.2.constant, oscillate: 0, mix: 1), 48000 * 2)
      expect(x[24000..].abs.max).to be < 1e-9
    end

    it 'whistles on several modes at once with a setting per mode, the dry signal once' do
      modes = (0..3).map { |m| klass.mode_frequency(8, 1000, mode: m) }
      x = collect(0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: -1.1, oscillate: [1, 3], mix: 1), 48000 * 3)
      t = top_lines(x[-32768..], 2)
      expect(t[0]).to be_within(3).of(modes[1])
      expect(t[1]).to be_within(3).of(modes[3])
      x = collect(0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: [-1.1, -0.5], oscillate: [1, 3], mix: 1), 48000 * 3)
      hz, next_db = lines(x[-32768..])
      expect(hz).to be_within(3).of(modes[1])
      expect(next_db).to be < -40
      x = collect(0.constant.phaser(stages: 8, depth: 0, feedback: -1.1, oscillate: [1, 3], level: [1, 0.25], pitch: [500, 1500], mix: 1), 48000 * 3)
      expect(top_lines(x[-32768..], 2).zip([500, 1500]).map { |a, b| (a - b).abs }.max).to be < 3

      saw = collect(110.hz.saw, 4800)
      expect(collect(110.hz.saw.phaser(oscillate: [0, 1], feedback: -1.1, wet: 0), 4800)).to eq(saw * 0.5)
      expect { 110.hz.saw.phaser(oscillate: [0, 1], feedback: [-1.1, -1.1, -1.1]) }.to raise_error(ArgumentError, /one setting per/)
      expect { 110.hz.saw.phaser(oscillate: 0, feedback: [-1.1]) }.to raise_error(ArgumentError, /list/)
      expect { 110.hz.saw.phaser(oscillate: []) }.to raise_error(ArgumentError, /at least one/)
      expect { 110.hz.saw.phaser(oscillate: [0, nil]) }.to raise_error(ArgumentError, /not nil/)
    end

    it 'checks modes against the stage count and the level against the loop' do
      expect { 110.hz.saw.phaser(stages: 2, feedback: 1.1, oscillate: 0) }.to raise_error(ArgumentError, /positive feedback/)
      expect { 110.hz.saw.phaser(stages: 8, feedback: -1.1, oscillate: 4) }.to raise_error(ArgumentError, /4 modes/)
      expect { 110.hz.saw.phaser(stages: 8, feedback: 1.1, oscillate: 3) }.to raise_error(ArgumentError, /3 modes/)
      expect { 110.hz.saw.phaser(level: 2) }.to raise_error(ArgumentError, /oscillate/)
      expect { 110.hz.saw.phaser(oscillate: 0, level: 0) }.to raise_error(ArgumentError, /level/)
      expect { 110.hz.saw.phaser(oscillate: -0.5) }.to raise_error(ArgumentError, /oscillate/)
    end

    it 'carries an oscillating loop across a rebuild on another mode' do
      a = 0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: -1.1, oscillate: 1, mix: 1)
      collect(a, 48000)
      b = 0.constant.phaser(stages: 8, center: 1000, depth: 0, feedback: -1.1, oscillate: 2, mix: 1)
      b.carry_adopt(a)
      expect(collect(b, 4800).abs.max).to be > 0.1 # (still whistling, moving to the new mode)
      plain = 0.constant.phaser(stages: 8, feedback: 0.5)
      plain.carry_adopt(a) # (another loop: starts fresh)
      expect(plain.instance_variable_get(:@state).length).to eq(9)
    end

    it 'oscillates in a barber pole: whistles that climb forever at a steady level' do
      x = collect(0.constant.phaser(:barberpole, feedback: -1.1, oscillate: 1, mix: 1), 48000 * 6)
      expect(x.isfinite.all?).to eq(true)
      expect(x.abs.max).to be < 2
      rms = (2...6).map { |i| Math.sqrt((x[(i * 48000)...((i + 1) * 48000)]**2).mean) }
      expect(rms.max / rms.min).to be < 1.1
    end

    it 'spreads lanes: phasers in series, their LFOs evenly around the circle (:circle)' do
      a = collect(110.hz.saw.phaser(0.5, stages: 4, feedback: 0.3, lanes: 4), 9600)
      x = 110.hz.saw
      4.times { |i| x = x.phaser(0.5, stages: 4, feedback: 0.3, phase: i / 4.0) }
      expect(a).to eq(collect(x, 9600))
      expect(klass.preset_names).to include(:circle)
      c = collect(110.hz.saw.phaser(:circle).mono, 48000)
      expect(c.isfinite.all?).to eq(true)
      expect(c.abs.max).to be < 2
      expect { 110.hz.saw.phaser(lanes: 0) }.to raise_error(ArgumentError, /lanes/)
      expect { 110.hz.saw.phaser(:barberpole, lanes: 2) }.to raise_error(ArgumentError, /lanes/)
      expect { 110.hz.saw.phaser(sweep: 1.hz.lfo, lanes: 2) }.to raise_error(ArgumentError, /lanes/)
    end

    it 'limits a barber pole to BARBER_MAX_HZ passes a second (direction at audio rate)' do
      fast = collect(110.hz.saw.phaser(:barberpole, direction: 1000.constant), 9600)
      expect(fast).to eq(collect(110.hz.saw.phaser(:barberpole, direction: 400.constant), 9600)) # (both 40 passes a second)
      expect { 110.hz.saw.phaser(:barberpole, direction: 401) }.to raise_error(ArgumentError, /passes a second/)
      expect { 110.hz.saw.phaser(:barberpole, rate: 20, direction: 2.5) }.to raise_error(ArgumentError, /passes a second/)
      expect { 110.hz.saw.phaser(:barberpole, rate: 1.n16, direction: 4) }.not_to raise_error
      # (a direction knob swung +-2 at 80 Hz barely moves the notches: its sweep integrates to +-0.002 octaves)
      held = collect(110.hz.saw.phaser(:barberpole, direction: 0), 48000)
      buzz = collect(110.hz.saw.phaser(:barberpole, direction: 80.hz.lfo.at(-2..2)), 48000)
      expect(Math.sqrt(((buzz - held)**2).mean) / Math.sqrt((held**2).mean)).to be < 0.05
    end

    it 'gives the same samples at any buffer size with the new options' do
      mk = -> {
        110.hz.saw.phaser(:jet, above: nil, rate: 3, stages: 8, feedback: 0.5.hz.lfo.at(-1.25..1.25), oscillate: 0.3.hz.lfo.at(0..3),
          level: 2.hz.lfo.at(0.5..2), pitch: 1.hz.lfo.at(400..900)) +
          110.hz.saw.phaser(2, stages: 4, feedback: -1.1, oscillate: [0, 1], lanes: 2) +
          110.hz.saw.phaser(:barberpole, rate: 3, feedback: -1.05, oscillate: 2, level: 0.5)
      }
      a = collect(mk.(), 48000)
      expect(collect(mk.(), 48000, [1, 7, 128, 33, 367])).to eq(a)
      expect(a.isfinite.all?).to eq(true)
    end

    it 'prints the effects-5 settings back as Ruby' do
      expect(110.hz.saw.phaser(stages: 8, feedback: -1.1, oscillate: [1, 3], level: 2, pitch: 440).to_ruby).to include('oscillate: [1, 3], level: 2, pitch: 440')
      expect(110.hz.saw.phaser(:circle).to_ruby).to include('phaser(:circle)')
    end
  end

  it 'prints the effects-3 settings back as Ruby' do
    node = 110.hz.saw.phaser(:jet, above: 150, amount: 0.7)
    expect(node.to_ruby).to include('phaser(:jet, above: 150, amount: 0.7)')
    expect(110.hz.saw.phaser(:barberpole, direction: :down).to_ruby).to include('phaser(:barberpole, direction: :down)')
  end
end
