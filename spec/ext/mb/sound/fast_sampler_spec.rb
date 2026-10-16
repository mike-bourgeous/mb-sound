require 'shellwords'

RSpec.describe('MB::Sound::FastSampler', :aggregate_failures) do
  let(:fast) { MB::Sound::FastSampler }
  let(:mirror) { MB::Sound::Sampler::KernelRuby }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_sampler.so', __dir__)
    code = 'require "bundler/setup"; require "numo/narray"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastSampler.respond_to?(:play)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  let(:rng) { Random.new(7) }

  # A decaying noisy tone: something with both highs and lows.
  def sound(n, freq: 300)
    Numo::SFloat.cast(Array.new(n) { |i| (Math.sin(i * 2 * Math::PI * freq / 48000) * 0.7 + (rng.rand - 0.5) * 0.3) * Math.exp(-i / (n * 0.6)) })
  end

  let(:base) { MB::Sound::Sample[sound(6000)] }

  def instrument(&block)
    MB::Sound::Sampler::Instrument.new(&block)
  end

  def signal(n, pairs, default = 0.0)
    a = Numo::SFloat.new(n).fill(default)
    pairs.each { |i, v| a[i] = v }
    a
  end

  # Runs the kernel and the mirror over +n+ samples in blocks of +block+
  # and expects identical samples, states, counters, and random states.
  # Returns the output.
  def compare(inst, n, inputs, block: 128, declick: 64, interpolation: :optimal, transpose: 0.0, seed: 99, mips: :default, choke_fade: 0)
    specs, regions = inst.kernel_tables(0, 48000, mips: mips, interpolation: interpolation)
    sinc = interpolation == :sinc ? MB::Sound::Wavetable::SINC_KERNEL : nil
    config = [440.0, declick, inst.split || -1, MB::Sound::Wavetable::INTERPOLATIONS[interpolation], sinc, transpose, 144, choke_fade]
    sa = Numo::DFloat.zeros(mirror::STATE_LENGTH)
    sa[mirror::LAST_REGION] = -1
    sb = sa.dup
    ca = Numo::DFloat.zeros(128)
    cb = ca.dup
    ra = Numo::UInt64[seed]
    rb = Numo::UInt64[seed]
    outs = []
    (0...n).step(block) do |at|
      len = [block, n - at].min
      ins = inputs.map { |x| x.is_a?(Numo::NArray) ? x[at...(at + len)].dup : x }
      a = Numo::SFloat.zeros(len)
      b = Numo::SFloat.zeros(len)
      fast.play(a, specs, regions, sa, ca, ra, ins, config)
      mirror.play(b, specs, regions, sb, cb, rb, ins, config)
      expect(a).to eq(b), "samples at #{at} (#{len})"
      expect(sa).to eq(sb), "state at #{at}"
      outs << a
    end
    expect(ca).to eq(cb)
    expect(ra).to eq(rb)
    Numo::SFloat.hstack(outs)
  end

  # The kernel alone at +block+ samples per call.
  def run(inst, n, inputs, block:, declick: 64, seed: 99)
    specs, regions = inst.kernel_tables(0, 48000)
    config = [440.0, declick, inst.split || -1, 3, nil, 0.0, 144, 0]
    st = Numo::DFloat.zeros(mirror::STATE_LENGTH)
    st[mirror::LAST_REGION] = -1
    cnt = Numo::DFloat.zeros(128)
    r = Numo::UInt64[seed]
    Numo::SFloat.hstack((0...n).step(block).map { |at|
      len = [block, n - at].min
      ins = inputs.map { |x| x.is_a?(Numo::NArray) ? x[at...(at + len)].dup : x }
      fast.play(Numo::SFloat.zeros(len), specs, regions, st, cnt, r, ins, config).dup
    })
  end

  it "reads each region as its sample says when the voice doesn't (lofi drop-sample reads)" do
    s = base.with(root: 60)
    drop = s.read_as(:drop)
    sinc = s.read_as(interpolation: :sinc)
    inst = instrument { |i|
      i.region(s, keys: 0..59)
      i.region(drop, keys: 60..71, root: 60)
      i.region(sinc, keys: 72..127, root: 72)
    }
    specs, regions = inst.kernel_tables(0, 48000)
    expect(regions[true, mirror::INTERP].to_a).to eq([3, 0, 4].map(&:to_f))
    expect(specs.length).to eq(3)

    n = 9000
    trig = signal(n, [[0, 1.0], [3000, 1.0], [6000, 1.0]])
    num = signal(n, [[0...3000, 55.0], [3000...6000, 67.0], [6000...n, 79.0]])
    sinc_kernel = MB::Sound::Wavetable::SINC_KERNEL
    config = ->(code) { [440.0, 64, -1, code, sinc_kernel, 0.0, 144, 0] }
    # (kernel_tables gives every region a code; -1 means config's)
    regions[0, mirror::INTERP] = -1
    outs = [3, 2].map { |code|
      sa = Numo::DFloat.zeros(mirror::STATE_LENGTH)
      sa[mirror::LAST_REGION] = -1
      sb = sa.dup
      a = Numo::SFloat.zeros(n)
      b = Numo::SFloat.zeros(n)
      fast.play(a, specs, regions, sa, Numo::DFloat.zeros(128), Numo::UInt64[1], [trig, num, nil, nil, 0.0, 0.0, nil], config.(code))
      mirror.play(b, specs, regions, sb, Numo::DFloat.zeros(128), Numo::UInt64[1], [trig, num, nil, nil, 0.0, 0.0, nil], config.(code))
      expect(a).to eq(b)
      a
    }
    # Only the region without a code follows config's
    expect(outs[0][0...3000]).not_to eq(outs[1][0...3000])
    expect(outs[0][3064...6000]).to eq(outs[1][3064...6000])
    expect(outs[0][6064..]).to eq(outs[1][6064..])

    # The drop region reads the raw samples: a fifth up, every output sample
    # is one of the sample's own values
    raw = s.data.to_a.map(&:to_f)
    expect(outs[0][3064...4000].to_a.all? { |v| raw.include?(v.to_f) }).to eq(true)

    # A sinc region needs the sinc kernel
    no_sinc = [440.0, 64, -1, 3, nil, 0.0, 144, 0]
    expect {
      fast.play(Numo::SFloat.zeros(10), specs, regions, Numo::DFloat.zeros(mirror::STATE_LENGTH).tap { |x| x[mirror::LAST_REGION] = -1 },
                Numo::DFloat.zeros(128), Numo::UInt64[1], [1.0, 60.0, nil, nil, 0.0, 0.0, nil], no_sinc)
    }.to raise_error(ArgumentError, /sinc kernel/)
    bad = regions.dup
    bad[0, mirror::INTERP] = 7
    expect {
      fast.play(Numo::SFloat.zeros(10), specs, bad, Numo::DFloat.zeros(mirror::STATE_LENGTH).tap { |x| x[mirror::LAST_REGION] = -1 },
                Numo::DFloat.zeros(128), Numo::UInt64[1], [1.0, 60.0, nil, nil, 0.0, 0.0, nil], config.(3))
    }.to raise_error(ArgumentError, /bad interpolation/)

    # The voice's own options win over the samples'
    _, all_cubic = inst.kernel_tables(0, 48000, interpolation: :cubic, mips: :octave)
    expect(all_cubic[true, mirror::INTERP].to_a.uniq).to eq([2.0])
  end

  it 'starts a one-shot on the trigger sample and ends at the end of the sample' do
    s = base
    inst = instrument { |i| i.region(s, keytrack: 0) }
    n = 8000
    out = compare(inst, n, [signal(n, [[100, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil])
    expect(out[0...100].abs.max).to eq(0)
    expect(out[100...6100].abs.max).to be > 0.3
    expect(out[6200..].abs.max).to eq(0)
    # At its own pitch with no levels crossfading, the sample plays back closely
    expect((out[100...6100] - s.data).abs.max).to be < 1e-3
  end

  it 'pitches by key from the root with keytrack and tune' do
    s = base.with(root: 60)
    inst = instrument { |i| i.region(s) }
    n = 6000
    up = compare(inst, n, [signal(n, [[0, 1.0]]), 72.0, nil, nil, 0.0, 0.0, nil])
    # An octave up plays the sample in half the samples
    expect(up[2900...3000].abs.max).to be > 0
    expect(up[3010..].abs.max).to eq(0)

    half = instrument { |i| i.region(s, keytrack: 0.5, tune: 1) }
    out = compare(half, n, [signal(n, [[0, 1.0]]), 72.0, nil, nil, 0.0, 0.0, nil])
    len = 6000 / 2**(7 / 12.0)
    expect(out[(len - 20).floor...(len - 2).floor].abs.max).to be > 0
    expect(out[(len + 2).ceil..].abs.max).to eq(0)
  end

  it 'follows the frequency input relative to the note (bends)' do
    s = base
    inst = instrument { |i| i.region(s) }
    n = 6000
    freq = Numo::SFloat.new(n).fill(440.0 * 2) # an octave above A4
    out = compare(inst, n, [signal(n, [[0, 1.0]]), 69.0, freq, nil, 0.0, 0.0, nil])
    # Root C4 played at A4 and bent an octave up
    len = 6000 / (2**(9 / 12.0) * 2)
    expect(out[(len + 2).ceil..].abs.max).to eq(0)
    expect(out[(len - 100).floor...(len - 2).floor].abs.max).to be > 0
  end

  it 'plays backwards, with fades' do
    s = base.rev.fade(in: 100, out: 200)
    inst = instrument { |i| i.region(s, keytrack: 0) }
    n = 6400
    out = compare(inst, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil])
    expect(out[0]).to eq(0)
    expect(out[50].abs).to be < out[150].abs + 0.5
    expect(out[6000..].abs.max).to eq(0)
  end

  it 'loops forward, ping-pong, and while held (release loops)' do
    n = 30_000
    fwd = base.looped(1000...3000)
    out = compare(instrument { |i| i.region(fwd, keytrack: 0) }, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil])
    expect(out[25_000..].abs.max).to be > 0.01

    pp = base.looped(1000...3000, mode: :ping_pong)
    out = compare(instrument { |i| i.region(pp, keytrack: 0) }, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil], block: 77)
    expect(out[25_000..].abs.max).to be > 0.01

    rel = base.looped(1000...3000, mode: :release)
    gate = signal(n, [], 1.0)
    gate[10_000..] = 0
    out = compare(instrument { |i| i.region(rel, keytrack: 0) }, n, [signal(n, [[0, 1.0]]), 60.0, nil, gate, 0.0, 0.0, nil], block: 800)
    expect(out[9000...10_000].abs.max).to be > 0.01
    expect(out[16_100..].abs.max).to eq(0) # the rest of the sample (3000 more at most) after the release
  end

  it 'loops reversed samples' do
    n = 20_000
    s = base.looped(1000...3000).rev
    out = compare(instrument { |i| i.region(s, keytrack: 0) }, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil], block: 333)
    expect(out[15_000..].abs.max).to be > 0.01
  end

  it 'picks regions by key, velocity, and round robins' do
    a = base.gain(0.25)
    b = base.gain(0.5)
    c = base
    inst = instrument { |i|
      i.region(a, keys: 60..60, vel: 0..63, keytrack: 0)
      i.region(b, keys: 60..60, vel: 64..127, seq: [1, 2], keytrack: 0)
      i.region(c, keys: 60..60, vel: 64..127, seq: [2, 2], keytrack: 0)
    }
    n = 4 * 6400
    trig = signal(n, [[0, 0.3], [6400, 0.9], [12_800, 0.9], [19_200, 0.9]])
    out = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], block: 800)
    peaks = (0...4).map { |k| out[(k * 6400)...((k + 1) * 6400)].abs.max }
    # Every note-on counts for the key's round robin, so notes 2, 3, and 4
    # are its 2nd, 3rd, and 4th: c, b, c
    expect(peaks[1] / peaks[0]).to be_within(0.05).of(4)
    expect(peaks[2] / peaks[1]).to be_within(0.05).of(0.5)
    expect(peaks[3]).to be_within(1e-6).of(peaks[1])
  end

  it 'picks random round robins from the seed, with velocity tracking' do
    a = base
    b = base.rev
    inst = instrument { |i|
      i.region(a, rand: 0.0...0.5, keytrack: 0, veltrack: 1)
      i.region(b, rand: 0.5...1.0, keytrack: 0, veltrack: 1)
    }
    n = 12_000
    trig = signal(n, (0...10).map { |k| [k * 1200, 0.2 + k * 0.08] })
    out1 = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], seed: 5)
    out2 = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], seed: 5)
    out3 = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], seed: 6)
    expect(out1).to eq(out2)
    expect(out1).not_to eq(out3)
  end

  it 'plays slices from keys, pitched by the shift (pitch mark) read at the note-on' do
    brk = base.slices(4)
    inst = brk.instrument # slices on C2 (36) up, then reversed
    n = 6000
    plain = compare(inst, n, [signal(n, [[0, 1.0]]), 38.0, nil, nil, 0.0, 0.0, nil])
    expect(plain[0...1490]).to eq(compare(MB::Sound::Sampler::Instrument.new { |i| i.region(brk[2], keytrack: 0) }, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, 0.0, 0.0, nil])[0...1490])
    shift = Numo::SFloat.new(n).fill(12.0)
    shift[100..] = 0 # read only at the note-on
    up = compare(inst, n, [signal(n, [[0, 1.0]]), 38.0, nil, nil, 0.0, shift, nil])
    expect(up[752..].abs.max).to eq(0) # 1500 samples an octave up
    expect(up[700...748].abs.max).to be > 0
    rev = compare(inst, n, [signal(n, [[0, 1.0]]), 38.0 + 4, nil, nil, 0.0, 0.0, nil])
    expect(rev[0...1500]).not_to eq(plain[0...1500])
    expect(rev[1500..].abs.max).to eq(0)
  end

  it 'plays the last slice chromatically above a split key' do
    brk = base.slices(4)
    inst = brk.keymap(from: 36, split: 60)
    expect(inst.regions.length).to eq(8)
    n = 8000
    trig = signal(n, [[0, 1.0], [2000, 1.0], [4000, 1.0]])
    num = Numo::SFloat.new(n).fill(37.0)
    num[2000...4000] = 72.0 # the last slice (1) an octave up
    num[4000..] = 60.0      # at its own pitch
    out = compare(inst, n, [trig, num, nil, nil, 0.0, 0.0, nil], block: 300)
    one = compare(MB::Sound::Sampler::Instrument.new { |i| i.region(brk[1], keytrack: 0) }, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil])
    expect(out[4000...5490]).to eq(one[4000...5490])
    expect(out[2752...4000].abs.max).to eq(0)
    expect(out[2700...2748].abs.max).to be > 0

    # Nothing played below the split yet: silence
    expect(compare(inst, 2000, [signal(2000, [[0, 1.0]]), 64.0, nil, nil, 0.0, 0.0, nil]).abs.max).to eq(0)
  end

  it 'fades a re-struck note out over the declick length' do
    s = base
    inst = instrument { |i| i.region(s, keytrack: 0) }
    n = 4000
    trig = signal(n, [[0, 1.0], [1000, 1.0]])
    out = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], declick: 64, block: 61)
    cut = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil], declick: 0)
    expect(out[0...1000]).to eq(cut[0...1000])
    expect(out[1000...1064]).not_to eq(cut[1000...1064])
    expect(out[1064..]).to eq(cut[1064..])
  end

  it 'stops a choked note 144 samples after the choke (fading with choke fade), unless a note-on comes first' do
    s = base
    inst = instrument { |i| i.region(s, keytrack: 0) }
    n = 6000
    trig = signal(n, [[0, 1.0], [3000, 1.0]])
    plain = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, nil])
    choke = signal(n, [[1000, 1.0], [1050, 1.0], [3000, 1.0], [4000, 1.0], [4100, 1.0]])
    [1, 77, 128, 800].each do |block|
      stop = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, choke], block: block)
      expect(stop[0...1144]).to eq(plain[0...1144]) # (a second choke while choking changes nothing)
      expect(stop[1144...3000].abs.max).to eq(0)
      expect(stop[3000...4144]).to eq(plain[0...1144]) # a note-on on a choke's sample wins (no tail: the first note stopped)
      expect(stop[4144..].abs.max).to eq(0)

      fade = compare(inst, n, [trig, 60.0, nil, nil, 0.0, 0.0, choke], block: block, choke_fade: 1)
      ramp = (Numo::DFloat.new(144).seq(144, -1) / 144.0).to_a
      expected = Numo::SFloat.cast(plain[1000...1144].to_a.zip(ramp).map { |x, g| x * g })
      expect(fade[0...1000]).to eq(plain[0...1000])
      expect((fade[1000...1144] - expected).abs.max).to be < 1e-7 # like Drums::ChokeGate (rounded once, from doubles)
      expect(fade[1144...3000].abs.max).to eq(0)
    end

    # A choke on a silent voice does nothing
    expect(compare(inst, 400, [0.0, 60.0, nil, nil, 0.0, 0.0, signal(400, [[10, 1.0]])]).abs.max).to eq(0)
    expect(compare(inst, 400, [signal(400, [[20, 1.0]]), 60.0, nil, nil, 0.0, 0.0, signal(400, [[10, 1.0]])])[20..]).to eq(plain[0...380])
  end

  it 'starts at a fraction of the region and at offsets' do
    s = base
    inst = instrument { |i| i.region(s, keytrack: 0, offset: 1000) }
    n = 6000
    out = compare(inst, n, [signal(n, [[0, 1.0]]), 60.0, nil, nil, Numo::SFloat.new(n).fill(0.5), 0.0, nil])
    expect(out[1990...1999].abs.max).to be > 0
    expect(out[2001..].abs.max).to eq(0) # 6000 - 1000 - 3000 left
  end

  it 'matches the mirror with every interpolation and without levels' do
    s = base
    inst = instrument { |i| i.region(s) }
    n = 3000
    ins = [signal(n, [[0, 1.0], [1500, 0.5]]), 66.5, nil, nil, 0.0, Numo::SFloat.new(n).fill(0.5), nil]
    [:none, :linear, :cubic, :optimal, :sinc].each do |interp|
      compare(inst, n, ins, interpolation: interp)
    end
    compare(inst, n, ins, mips: false, interpolation: :cubic)
  end

  it 'gives the same samples at any buffer size' do
    s = base.looped(500...2500, mode: :ping_pong)
    inst = instrument { |i| i.region(s) }
    n = 9000
    trig = signal(n, [[3, 1.0], [2500, 0.7], [2501, 0.6], [7000, 1.0]])
    num = Numo::SFloat.new(n).fill(62.0)
    num[2500..] = 70.5
    freq = Numo::SFloat.cast(Array.new(n) { |i| 440 * 2**(Math.sin(i / 300.0) / 12) })
    ref = run(inst, n, [trig, num, freq, nil, 0.0, 0.0, nil], block: n)
    [1, 7, 128, 367, 800].each do |b|
      expect(run(inst, n, [trig, num, freq, nil, 0.0, 0.0, nil], block: b)).to eq(ref), "block #{b}"
    end
  end

  it 'rejects bad arguments' do
    inst = instrument { |i| i.region(base) }
    specs, regions = inst.kernel_tables(0, 48000)
    st = Numo::DFloat.zeros(mirror::STATE_LENGTH)
    cnt = Numo::DFloat.zeros(128)
    r = Numo::UInt64[1]
    st[mirror::LAST_REGION] = -1
    cfg = [440.0, 64, -1, 3, nil, 0.0, 144, 0]
    ins = [0.0, 60.0, nil, nil, 0.0, 0.0, nil]
    out = Numo::SFloat.zeros(10)
    expect { fast.play(out, specs, regions, st, cnt, r, ins[0..3], cfg) }.to raise_error(ArgumentError, /inputs/)
    expect { fast.play(out, specs, regions, st, cnt, r, ins, cfg[0..4]) }.to raise_error(ArgumentError, /config/)
    expect { fast.play(out, specs, regions, st, cnt, r, ins, cfg[0..5] + [0, 0]) }.to raise_error(ArgumentError, /choke length/)
    expect { fast.play(out, specs, regions, Numo::DFloat.zeros(3), cnt, r, ins, cfg) }.to raise_error(ArgumentError, /state/)
    expect { fast.play(out, specs, regions, st, Numo::DFloat.zeros(3), r, ins, cfg) }.to raise_error(ArgumentError, /counters/)
    expect { fast.play(out, specs, regions.cast_to(Numo::SFloat), st, cnt, r, ins, cfg) }.to raise_error(ArgumentError, /regions/)
    expect { fast.play(out, [], regions, st, cnt, r, ins, cfg) }.to raise_error(ArgumentError, /table/)
    expect { fast.play(out, specs, regions, st, cnt, r, ins, [440.0, 64, 200, 3, nil, 0.0, 144, 0]) }.to raise_error(ArgumentError, /split/)
    expect { fast.play(out, specs, regions, st, cnt, r, ins, [440.0, 64, -1, 9, nil, 0.0, 144, 0]) }.to raise_error(ArgumentError, /interpolation/i)
    bad = st.dup
    bad[mirror::LAST_REGION] = 5
    expect { fast.play(out, specs, regions, bad, cnt, r, ins, cfg) }.to raise_error(ArgumentError, /last region/)
  end
end
