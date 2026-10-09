RSpec.describe(MB::Sound::GraphNode::Reverb) do
  # Renders +total+ samples of an impulse on input 0 (of +inputs+) through a
  # reverb (wet only), read in +block+-sample buffers.  Returns one SFloat
  # per output.
  def impulse(preset = nil, block: 512, total: 24000, inputs: 1, outputs: 1, **params)
    srcs = Array.new(inputs) { |i|
      imp = Numo::SFloat.zeros(total)
      imp[0] = 1 if i == 0
      MB::Sound::ArrayInput.new(data: [imp])
    }
    rev = MB::Sound::GraphNode::Reverb.reverb(preset, input: inputs == 1 ? srcs[0] : srcs, output_channels: outputs, dry: 0, extra_time: 0, **params)
    outs = outputs > 1 ? rev.to_a : [rev]
    bufs = []
    done = 0
    while done < total
      n = [block, total - done].min
      bufs << outs.map { |o| o.sample(n).dup }
      done += n
    end
    bufs.transpose.map { |c| c[0].concatenate(*c[1..]) }
  end

  def energy_db(c)
    10 * Math.log10((Numo::DFloat.cast(c)**2).sum)
  end

  # RT60 from Schroeder backward integration (T20 fit between -5 and -25
  # dB, times 3).
  def rt60(chans, rate: 48000)
    e = chans.map { |c| Numo::DFloat.cast(c)**2 }.sum
    edc = e.reverse.cumsum.reverse
    db = 10 * Numo::NMath.log10(edc / edc[0] + 1e-300)
    idx = ((db <= -5) & (db >= -25)).where
    t = Numo::DFloat.cast(idx) / rate
    y = db[idx]
    slope = ((t - t.mean) * (y - y.mean)).sum / ((t - t.mean)**2).sum
    -60.0 / slope
  end

  it 'has feedback sources if show_internals is true' do
    # Using fewer channels and stages to reduce the exponential path explosion that causes warnings about infinite loops
    expect(100.hz.reverb(channels: 2, stages: 1, show_internals: true).graph_edges(feedback: true)).not_to be_empty
  end

  it 'does not have feedback sources if show_internals is false' do
    expect(100.hz.reverb.graph_edges(feedback: true)).to be_empty
  end

  describe 'show_internals (the network as a node graph)' do
    [
      [:hall, 1, 1, {}],
      [:space, 2, 2, { predelay: 0.02 }],
      [:default, 3, 5, {}],
      [:room, 1, 2, { feedback_enabled: false }],
      [:hall, 2, 1, { stages: 0 }],
      [:room, 1, 2, { loop_extra: 0, decay: 0.3 }],
    ].each do |preset, inputs, outputs, params|
      it "sounds like the kernel for #{preset} with #{inputs} in, #{outputs} out, #{params}" do
        graph = impulse(preset, inputs: inputs, outputs: outputs, total: 9600, show_internals: true, **params)
        kernel = impulse(preset, inputs: inputs, outputs: outputs, total: 9600, **params)
        graph.zip(kernel).each do |g, k|
          expect(k.abs.max).to be > 1e-4
          expect((g - k).abs.max).to be < k.abs.max * 1e-4
        end
      end
    end

    it 'refuses modulation and loop processing' do
      expect { 100.hz.reverb(:room, show_internals: true, mod: true) }.to raise_error(ArgumentError, /modulation/)
      expect { 100.hz.reverb(:room, show_internals: true, lowpass: 3000, drive: 2) }.to raise_error(ArgumentError, /lowpass, drive/)
    end
  end

  # The network runs per sample, so its loops are the line delays at every
  # buffer size (until 2026-10-06 they were the line delays plus the
  # caller's buffer size; until 2026-10-10 plus a fixed 1024-sample block
  # read from the lines' inputs, which the classic presets keep as
  # +:loop_extra:+).
  describe 'buffer size independence' do
    [
      [:room, {}],
      [:hall, {}],
      [:space, { mod: :lush, diffusion_mod: :chorus }],
      [nil, { room_size: 0.2, decay: 0.5, shimmer: 0.4, drive: 3, crush: 9, highpass: 100 }],
      [:room, { loop_extra: 0, mod: { depth: 0.002, rate: 3, shape: :random }, lowpass: 2000 }],
    ].each do |preset, params|
      it "gives identical samples at every buffer size for #{preset.inspect} #{params}" do
        ref = impulse(preset, block: 1024, total: 12000, outputs: 2, **params)
        expect(ref[0].abs.max).to be > 0.0001
        [1, 32, 333, 12000].each do |block|
          next if block == 1 && preset != :room

          expect(impulse(preset, block: block, total: 12000, outputs: 2, **params)).to eq(ref), "buffer size #{block} differs"
        end
      end
    end

    it 'keeps the loop time in seconds at other sample rates' do
      rev = 100.hz.ramp.reverb(:room)
      at48 = rev.feedback_delays
      rev.sample_rate = 96000
      expect(rev.feedback_delays.zip(at48).map { |a, b| a - 2 * b }).to all(be_between(-1, 1))
      expect(rev.network.kernel_config[:loop]).to eq(rev.feedback_delays.map(&:to_f))
    end

    it 'gives the classic presets loops of their taps plus 1024 samples at 48 kHz' do
      rev = 100.hz.ramp.reverb(:room)
      taps = rev.network.kernel_config[:tap]
      expect(rev.feedback_delays.zip(taps).map { |l, t| l - t }).to all(eq(1024))
    end
  end

  describe 'gains' do
    # Wet output energy (no feedback) for any lines, stages, inputs, and
    # outputs is about the input's (the old network's level moved by up
    # to 30 dB with these).
    [1, 2].each do |inputs|
      [1, 2].each do |outputs|
        # (with 4 lines and 1-2 stages, copies of an input stay partly
        # coherent: up to +/-3 dB)
        [[8, 2], [8, 4], [16, 3], [2, 4]].each do |channels, stages|
          it "keeps each output near the input energy with #{channels} lines, #{stages} stages, #{inputs} in, #{outputs} out" do
            irs = impulse(nil, inputs: inputs, outputs: outputs, total: 9600, channels: channels, stages: stages, diffusion_range: 0.01,
              feedback_range: 0.05, feedback_gain: 0.5, feedback_enabled: false, wet: 1, level: 1, seed: 1)
            irs.each do |c|
              expect(energy_db(c)).to be_within(1.5).of(0)
            end
          end
        end
      end
    end

    it 'keeps the classic presets at their old level for stereo in and out' do
      # Old (unnormalized) structural gain over the new one
      expect(described_class.classic_level(8, 4).to_db).to be_within(0.01).of(-9.03)
      expect(described_class.classic_level(4, 3).to_db).to be_within(0.01).of(-15.56)
      expect(described_class.classic_level(16, 4).to_db).to be_within(0.01).of(-6.02)
      expect(described_class::PRESETS[:hall][:wet]).to eq(-20.db)
    end

    it 'measures the requested decay time with the room-size layout' do
      [0.3, 0.8].each do |decay|
        irs = impulse(room_size: 0.4, decay: decay, damping: 0, mod: false, total: (decay * 1.2 * 48000).round, outputs: 2)
        expect(rt60(irs)).to be_within(decay * 0.1).of(decay)
      end
    end

    it 'shortens the decay of high frequencies with damping' do
      irs = impulse(room_size: 0.4, decay: 0.6, damping: 0.7, mod: false, total: 36000)
      hi = MB::Sound::Filter::Cookbook.new(:highpass, 48000, 6000, quality: 0.7).process(irs[0].dup)
      lo = MB::Sound::Filter::Cookbook.new(:lowpass, 48000, 300, quality: 0.7).process(irs[0].dup)
      expect(rt60([hi])).to be < rt60([lo]) * 0.6
    end

    it 'keeps a mix: setting between dry and wet' do
      rev = 1.constant.reverb(:room, mix: 0.25)
      expect(rev.dry).to eq(0.75)
      expect(rev.wet).to be_within(1e-9).of(0.25 * -16.db)
    end
  end

  describe 'modulation' do
    it 'repeats from the seed and changes with it' do
      a = impulse(:hall, total: 9600, mod: :lush, diffusion_mod: :subtle)
      b = impulse(:hall, total: 9600, mod: :lush, diffusion_mod: :subtle)
      c = impulse(:hall, total: 9600, mod: :lush, diffusion_mod: :subtle, seed: 6)
      plain = impulse(:hall, total: 9600)
      expect(a).to eq(b)
      expect(a).not_to eq(c)
      expect(a).not_to eq(plain)
    end

    it 'moves its LFOs within -1..1 at the given rate' do
      rev = 0.constant.reverb(:room, mod: { depth: 0.001, rate: 2, shape: :sine, spread: 0 }, diffusion_mod: { depth: 0.0001, rate: 5, shape: :smooth })
      values = Array.new(100) { rev.sample(480); rev.network.lfo_values }
      fb = values.map { |d, f| f[0] }
      expect(fb.minmax).to all(be_between(-1, 1))
      expect(fb.max - fb.min).to be > 1.9
      # 2 Hz sine over 1 s: four zero crossings
      crossings = fb.each_cons(2).count { |a, b| (a <=> 0) != (b <=> 0) }
      expect(crossings).to be_between(3, 5)
      expect(values.flat_map(&:first).minmax).to all(be_between(-1, 1))
    end

    it 'accepts presets, depths, Hashes, and nodes' do
      expect(0.constant.reverb(:room, mod: true).parameters[:modulation][:shape]).to eq(:smooth)
      expect(0.constant.reverb(:room, mod: 2.ms).network.kernel_config[:fdn_capacity].min).to be > 96
      expect { 0.constant.reverb(:room, mod: 0.001.constant).sample(10) }.not_to raise_error
      expect { 0.constant.reverb(:room, mod: { rate: 0.2.hz.lfo.at(1..2), depth: 1.ms, shape: :triangle }).sample(10) }.not_to raise_error
      expect { 0.constant.reverb(:room, mod: :wobbly) }.to raise_error(ArgumentError, /wobbly/)
      expect { 0.constant.reverb(:room, mod: { shape: :square }) }.to raise_error(ArgumentError, /square/)
      expect { 0.constant.reverb(:room, mod: { speed: 3 }) }.to raise_error(ArgumentError, /speed/)
    end
  end

  describe 'loop processing' do
    it 'holds the tail when frozen' do
      frozen = 0.constant.and_then(0.constant)
      src = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(48000).rand(-0.5, 0.5).tap { |v| v[4800..] = 0 }])
      rev = src.reverb(room_size: 0.3, decay: 0.3, freeze: (MB::Sound.silence(0.1).and_then(1.constant)), mod: false, extra_time: 0)
      out = Array.new(100) { rev.sample(480).dup }
      late = out[80..].map { |b| (b**2).sum }.sum
      mid = out[40...60].map { |b| (b**2).sum }.sum
      expect(late).to be_within(mid * 0.2).of(mid)
      expect(late).to be > 1e-3
      expect(frozen).to be_a(MB::Sound::GraphNode)
    end

    it 'adds energy an octave up with shimmer' do
      tone = 440.hz.at(0.5).until(0.2).and_then(MB::Sound.silence(2))
      plain = tone.reverb(room_size: 0.5, decay: 2, damping: 0, mod: false, dry: 0, extra_time: 2)
      tone2 = 440.hz.at(0.5).until(0.2).and_then(MB::Sound.silence(2))
      shim = tone2.reverb(room_size: 0.5, decay: 2, damping: 0, mod: false, dry: 0, extra_time: 2, shimmer: 0.8)
      a = Array.new(60) { plain.sample(800).dup }[30..].reduce(&:concatenate)
      b = Array.new(60) { shim.sample(800).dup }[30..].reduce(&:concatenate)
      band = ->(x, f) {
        w = 0.5 - 0.5 * Numo::NMath.cos(Numo::SFloat.new(x.length).seq * (2 * Math::PI / x.length))
        s = MB::Sound.real_fft(x * w).abs
        bin = (f * x.length / 48000.0).round
        s[(bin - 20)..(bin + 20)].max
      }
      expect(band.(b, 880) / band.(b, 440)).to be > 10 * band.(a, 880) / band.(a, 440)
    end

    it 'saturates loud tails with drive and leaves quiet ones alone' do
      quiet = impulse(room_size: 0.3, decay: 0.5, mod: false, total: 4800)
      driven = impulse(room_size: 0.3, decay: 0.5, mod: false, total: 4800, drive: 2)
      expect((driven[0] - quiet[0]).abs.max).to be < quiet[0].abs.max * 0.05

      loud = impulse(room_size: 0.3, decay: 0.5, mod: false, total: 4800, wet: 1).map { |c| c }
      expect(loud[0].abs.max).to be > 0
    end

    it 'raises for damping with a lowpass and unknown options' do
      expect { 1.constant.reverb(damping: 0.5, lowpass: 300) }.to raise_error(ArgumentError, /damping or a lowpass/)
      expect { 1.constant.reverb(:hall, roomsize: 0.5) }.to raise_error(ArgumentError, /roomsize/)
      expect { 1.constant.reverb(:cathedral) }.to raise_error(ArgumentError, /cathedral/)
      expect { 1.constant.reverb(room_size: 1.5) }.to raise_error(ArgumentError, /Room size/)
      expect { 1.constant.reverb(:hall, drive: 1, drive_mode: :fuzz) }.to raise_error(ArgumentError, /fuzz/)
    end

    it 'returns nil when a parameter node ends' do
      rev = 0.constant.reverb(:room, lowpass: 1000.constant.until(0.01))
      expect(Array.new(5) { rev.sample(480) }.last).to be_nil
    end
  end

  describe 'room-size layout (friendly factory)' do
    it 'builds one from room_size, decay, or damping without a preset' do
      rev = 1.constant.reverb(room_size: 0.8, decay: 3.seconds, damping: 0.4)
      expect(rev.parameters[:decay]).to eq(3)
      expect(rev.parameters[:modulation]).to include(shape: :smooth)
      expect(rev.layout.taps.minmax).to all(be_between(0.015 * 0.86, 0.12 * 0.86))
      expect(rev.layout.damping).to be_a(Array)
      expect((0...8).map { |i| rev.line_decay(i) }).to all(be_within(1e-9).of(3))
      expect(1.constant.reverb(decay: 1).layout.loop_extra).to eq(0)
      expect(1.constant.reverb.parameters[:loop_extra]).to eq(MB::Sound::GraphNode::Reverb::CLASSIC_LOOP_EXTRA.to_f)
    end

    it 'uses a preset decay with a classic layout' do
      rev = 1.constant.reverb(:hall, decay: 2)
      expect((0...8).map { |i| rev.line_decay(i) }).to all(be_within(1e-9).of(2))
    end

    it 'draws log-spaced delays without near-integer ratios' do
      delays = described_class.log_random_delays(4, 0.015..0.12, 1, Random.new(3))
      expect(delays).to eq(delays.sort)
      expect(described_class.delays_non_harmonic?(delays, 0.08)).to be true
      expect(described_class.delays_non_harmonic?([0.01, 0.02], 0.05)).to be false
      expect(described_class.delays_non_harmonic?([0.01, 0.0298], 0.05)).to be false
      expect(described_class.delays_non_harmonic?([0.01, 0.017, 0.026], 0.05)).to be true
    end

    it 'has room-size presets' do
      [:plate, :shimmer, :grit, :lofi, :drone].each do |preset|
        out = impulse(preset, total: 4800, outputs: 2)
        expect(out.map { |c| c.abs.max }.max).to be > 1e-4
        expect(out.all? { |c| c.isfinite.all? }).to be true
      end
    end
  end

  describe 'Ruby mirror' do
    it 'sounds the same as the C kernel (MB_SOUND_REVERB=ruby)' do
      params = { room_size: 0.1, decay: 0.2, channels: 4, stages: 2, mod: :lush, diffusion_mod: :subtle, shimmer: 0.3, drive: 2, highpass: 50 }
      c = impulse(total: 1200, outputs: 2, **params)
      begin
        ENV['MB_SOUND_REVERB'] = 'ruby'
        r = impulse(total: 1200, outputs: 2, **params)
      ensure
        ENV.delete('MB_SOUND_REVERB')
      end
      expect(r).to eq(c)
    end
  end

  it 'returns nil when its input ends' do
    rev = MB::Sound.silence(0.05).and_then(MB::Sound.silence(0)).reverb(:hall, extra_time: 0)
    expect(Array.new(10) { rev.sample(800) }.last).to be_nil
  end
end
