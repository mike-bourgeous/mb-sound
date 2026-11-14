RSpec.describe(MB::Sound::Sample::Spectral, :aggregate_failures) do
  let(:t) { Numo::DFloat.new(24000).seq / 48000 }
  let(:chord) { Numo::NMath.sin(t * 2 * Math::PI * 220) * 0.4 + Numo::NMath.sin(t * 2 * Math::PI * 330) * 0.3 }
  let(:pad) { MB::Sound::Sample[[chord, chord * 0.5]] }

  # The strongest frequency (Hz) of the middle 8192 samples of +d+.
  def peak_hz(d)
    m = d.length / 2
    seg = Numo::DFloat.cast(d[(m - 4096)...(m + 4096)])
    (Numo::Pocketfft.rfft(seg * MB::Sound::Sample::Spectral.hann(8192)).abs.max_index * 48000.0 / 8192)
  end

  def rms(d)
    Math.sqrt((Numo::DFloat.cast(d)**2).mean)
  end

  it 'stretches with the phase vocoder, keeping length, pitch, level, and the stereo balance' do
    [0.75, 2, 8].each do |r|
      s = pad.stretch(r, mode: :spectral)
      expect(s.length).to eq((pad.length * r).round)
      expect(peak_hz(s.data(0))).to be_within(6).of(220)
      expect(rms(s.data(0)) / rms(chord)).to be_within(0.06).of(1)
      expect(rms(s.data(1)) / rms(s.data(0))).to be_within(0.01).of(0.5)
    end
  end

  it 'gives back the input at ratio 1 (away from the edges)' do
    s = MB::Sound::Sample[chord].stretch(1, mode: :spectral, transients: false)
    expect((s.data(0)[4096...-4096] - Numo::SFloat.cast(chord)[4096...-4096]).abs.max).to be < 1e-3
  end

  it 'keeps attacks sharp at transients' do
    r = Random.new(1)
    x = Numo::DFloat.zeros(48000)
    [6000, 30000].each { |o| 3000.times { |i| x[o + i] = (r.rand * 2 - 1) * Math.exp(-i / 500.0) } }
    rise = ->(d, c) {
      w = d.abs[(c - 20000)...(c + 20000)]
      (w > w.max * 0.5).where[0] - (w > w.max * 0.05).where[0]
    }
    sharp = MB::Sound::Sample[x].stretch(4, mode: :spectral).data(0)
    smeared = MB::Sound::Sample[x].stretch(4, mode: :spectral, transients: false).data(0)
    expect(rise.(sharp, 24000)).to be < 20
    expect(rise.(smeared, 24000)).to be > 500

    # Paulstretch keeps frames holding an attack unrandomized with transients: true
    paul = MB::Sound::Sample[x].stretch(4, mode: :paul, transients: true).data(0)
    expect(rise.(paul, 24000)).to be < 20
    expect(rms(paul[24000...24480]) / rms(x[6000...6480])).to be_within(0.05).of(1)
    expect(rise.(MB::Sound::Sample[x].stretch(4, mode: :paul).data(0), 24000)).to be > 2000
  end

  it 'lands every hit of a dense pattern at ratio times its time, under a ringing bass' do
    # Hits 107 ms apart (16ths at 140 BPM, about a span apart: granular-1
    # merged their spans into one unstretched run, holding the first hit
    # and rushing the rest) over a 55 Hz tone that keeps ringing
    r = Random.new(2)
    x = Numo::NMath.sin(Numo::DFloat.new(60000).seq * (2 * Math::PI * 55 / 48000)) * 0.3
    hits = (0...10).map { |k| 4000 + k * 5143 }
    hits.each { |o| 800.times { |i| x[o + i] += (r.rand * 2 - 1) * Math.exp(-i / 150.0) } }
    s = MB::Sound::Sample[x]
    [2, 4].each do |ratio|
      y = s.stretch(ratio, mode: :spectral)
      found = MB::Sound::Sample[y.data].onsets
      hits.each { |o| expect(found.map { |f| (f - o * ratio).abs }.min).to be <= 48 } # 1 ms
      # no dip before the hits: the bass keeps its phase through the resets
      env = ->(c) { (1..12).map { |k| rms(y.data[(c - k * 256)...(c - k * 256 + 256)]) } }
      hits.drop(1).each { |o| expect(env.(o * ratio).min).to be > 0.1 }
    end
  end

  it 'Paulstretches with seeded random phases at the input level' do
    a = pad.stretch(8, mode: :paul)
    b = pad.stretch(8, mode: :paulstretch)
    c = pad.stretch(8, mode: :paul, seed: 3)
    expect(a.length).to eq(pad.length * 8)
    expect(a.data(0).to_a).to eq(b.data(0).to_a)
    expect(a.data(0).to_a).not_to eq(c.data(0).to_a)
    expect(rms(a.data(0)) / rms(chord)).to be_within(0.15).of(1)
  end

  # The share of the energy within ±20 Hz of +hz+ that lies more than
  # 1.5 Hz from it, in the middle 65536 samples of +d+ (how far random
  # phases spread a partial).
  def spread(d, hz)
    n = 65536
    m = d.length / 2
    p = Numo::Pocketfft.rfft(Numo::DFloat.cast(d[(m - n / 2)...(m + n / 2)]) * described_class.hann(n)).abs**2
    df = 48000.0 / n
    near = ((hz - 20) / df).round..((hz + 20) / df).round
    core = ((hz - 1.5) / df).round..((hz + 1.5) / df).round
    1 - p[core].sum / p[near].sum
  end

  it 'goes from the vocoder to Paulstretch with randomize:, keeping the level' do
    s = MB::Sound::Sample[Numo::DFloat.cast(chord).concatenate(chord)]
    expect(s.stretch(4, mode: :spectral, randomize: 0).data.to_a).to eq(s.stretch(4, mode: :spectral).data.to_a)
    widths = [0, 0.5, 1].map { |r|
      y = s.stretch(6, mode: :spectral, randomize: r)
      expect(rms(y.data[20000...-20000]) / rms(chord)).to be_within(0.1).of(1)
      expect(peak_hz(y.data)).to be_within(6).of(220) if r < 1
      spread(y.data, 220)
    }
    expect(widths[0]).to be < widths[1]
    expect(widths[1]).to be < widths[2]
    expect(s.stretch(4, mode: :spectral, randomize: 0.5, seed: 2).data.to_a).not_to eq(s.stretch(4, mode: :spectral, randomize: 0.5).data.to_a)
    expect(s.stretch(4, mode: :spectral, randomize: 0.5).lineage[3]).to eq({ mode: :spectral, randomize: 0.5 })
    expect(s.stretch(4, mode: :paul, randomize: 0.5).lineage[3]).to eq({ mode: :paul, randomize: 0.5 })
    expect { s.stretch(4, mode: :spectral, randomize: 1.5) }.to raise_error(ArgumentError, /randomize/)
    expect { s.stretch(4, randomize: 0.5) }.to raise_error(ArgumentError, /spectral/)
  end

  it "narrows Paulstretch partials with the original's window and overlap (shape: :paul, overlap: 2)" do
    # Random phases smear each partial over the band of the frames'
    # windows; Nasca Paul's flatter (1 - x²)^1.25 at overlap 2 smears
    # less than Hann at overlap 4 (measured: 6.6 vs 10.3 Hz wide at -6 dB)
    sine = MB::Sound::Sample[Numo::NMath.sin(Numo::DFloat.new(72000).seq * (2 * Math::PI * 440 / 48000)) * 0.5]
    avg = ->(**kw) { (0..3).sum { |sd| spread(sine.stretch(8, mode: :paul, seed: sd, **kw).data, 440) } / 4 }
    hann = avg.()
    orig = avg.(overlap: 2, shape: :paul)
    expect(orig).to be < 0.85 * hann
    two = sine.stretch(8, mode: :paul, overlap: 2, shape: :paul)
    expect(rms(two.data) / rms(sine.data)).to be_within(0.15).of(1)
    expect(two.lineage[3]).to eq({ mode: :paul, overlap: 2, shape: :paul })
    expect { sine.stretch(2, mode: :paul, shape: :kaiser) }.to raise_error(ArgumentError, /window shape/)
  end

  it 'draws random phases per channel with link: false' do
    st = MB::Sound::Sample[[chord, chord]]
    corr = ->(s) { a = Numo::DFloat.cast(s.data(0)); b = Numo::DFloat.cast(s.data(1)); (a * b).sum / Math.sqrt((a * a).sum * (b * b).sum) }
    expect(corr.(st.stretch(8, mode: :paul))).to be > 0.999
    expect(corr.(st.stretch(8, mode: :paul, link: false)).abs).to be < 0.3
    expect(corr.(st.stretch(8, mode: :spectral, randomize: 0.5, link: false))).to be_between(0.3, 0.99)
    expect(st.stretch(8, mode: :paul, link: false).lineage[3]).to eq({ mode: :paul, link: false })
  end

  it 'makes random phases independent of how the work is split' do
    a = described_class.random_phases(5, 3, 100)
    expect(a.min).to be >= 0
    expect(a.max).to be < 1
    expect(described_class.random_phases(5, 3, 50).to_a).to eq(a[0...50].to_a)
    expect(described_class.random_phases(5, 4, 50).to_a).not_to eq(a[0...50].to_a)
  end

  it 'caches stretches and prints them through the lineage' do
    expect(pad.stretch(2, mode: :spectral)).to equal(pad.stretch(2, mode: :pv))
    expect(pad.stretch(2, mode: :spectral).lineage[3]).to eq({ mode: :spectral })
    expect(pad.stretch(2).lineage[3]).to eq({})
  end

  it 'reads stretches longer than 30 s with octave-spaced levels unless the sample has its own' do
    short = MB::Sound::Sample[chord]
    expect(short.stretch(8, mode: :paul).mips).to be_nil
    expect(short.stretch(64, mode: :paul).mips).to eq(:octave)
    expect(short.stretch(64).mips).to eq(:octave)
    expect(short.read_as(mips: :half_octave).stretch(64, mode: :paul).mips).to eq(:half_octave)
    expect(short.read_as(:drop).stretch(64, mode: :paul).mips).to eq(false)
  end

  describe 'loops (wrap:)' do
    # A pad that loops seamlessly: partials with whole numbers of cycles
    # in one second, and a slow swell that also closes
    let(:held) {
      i = Numo::DFloat.new(48000).seq / 48000
      (Numo::NMath.sin(i * (2 * Math::PI * 110)) * 0.3 + Numo::NMath.sin(i * (2 * Math::PI * 165) + 1) * 0.2 + Numo::NMath.sin(i * (2 * Math::PI * 331) + 2) * 0.1) *
        (0.8 + 0.2 * Numo::NMath.cos(i * (2 * Math::PI * 2)))
    }
    let(:plain) { MB::Sound::Sample[Numo::SFloat.cast(held)] }

    # [the step from the last sample back to the first, the largest step
    # between neighbours inside]
    def wrap_step(d)
      d = Numo::DFloat.cast(d)
      [(d[0] - d[-1]).abs, (d[1..] - d[0...-1]).abs.max]
    end

    # [the largest spectral flux across the wrap, the largest inside a
    # pass] of three passes of +d+: the change between the magnitude
    # spectra of 2048-sample frames 1024 samples apart, as a share of
    # their sum
    def flux(d)
      d = Numo::DFloat.cast(d)
      l = d.length
      tiled = Numo::DFloat.zeros(3 * l)
      3.times { |k| tiled[(k * l)...((k + 1) * l)] = d }
      w = MB::Sound::Sample::Spectral.hann(2048)
      mags = (0...((tiled.length - 2048) / 512)).map { |k| Numo::Pocketfft.rfft(tiled[(k * 512)...(k * 512 + 2048)] * w).abs }
      at = []
      inside = []
      (2...mags.length).each do |k|
        f = (mags[k] - mags[k - 2]).abs.sum / (mags[k].sum + mags[k - 2].sum)
        ([l, 2 * l].any? { |e| (k - 2) * 512 < e && e < k * 512 + 2048 } ? at : inside) << f
      end
      [at.max, inside.max]
    end

    it 'stretches a looping sample as an endless stream: no step and no change of tone at the wrap' do
      step, inside = wrap_step(held)
      expect(step).to be < inside
      at, within = flux(held)
      expect(at).to be < within
      [0.77, 1.25].each do |r|
        old = plain.looped.stretch(r, mode: :spectral, wrap: false)
        new = plain.looped.stretch(r, mode: :spectral)
        # (a stretch with its own ends stops wherever its phases have
        # got to: a step at every pass of the loop, and a jump in tone)
        expect(wrap_step(old.data(0))[0]).to be > 3 * inside
        at, within = flux(old.data(0))
        expect(at).to be > 4 * within
        step, inside_now = wrap_step(new.data(0))
        expect(step).to be < inside
        expect(inside_now).to be < 1.2 * inside
        at, within = flux(new.data(0))
        expect(at).to be < within
        expect(rms(new.data(0)) / rms(held)).to be_within(0.02).of(1)
        expect(new.length).to eq((48000 * r).round)
        expect(new).to be_whole_loop
        # Every partial comes round to its starting phase
        report = {}
        described_class.looped([held], r, report: report)
        expect(report[:closure][0]).to be > 0.1
        expect(report[:closure][1]).to be < 0.01
      end
    end

    it 'stretches several passes as one piece (passes:), and Paulstretch loops too' do
      loop = plain.looped.with(bpm: 120, beats: 2)
      three = loop.stretch(1.25, mode: :spectral, passes: 3)
      expect([three.length, three.beats, three.bpm]).to eq([180000, 6, 96.0])
      expect(three).to be_whole_loop
      at, within = flux(three.data(0))
      expect(at).to be < within
      # (its passes differ in their phases: the middle one alone does not loop)
      at, within = flux(three.data(0)[60000...120000])
      expect(at).to be > 2 * within
      expect(three.lineage[3]).to eq({ mode: :spectral, passes: 3 })
      expect { plain.stretch(1.25, mode: :spectral, passes: 2) }.to raise_error(ArgumentError, /passes: is 1 or more, for a sample that loops/)
      expect { loop.stretch(1.25, passes: 2) }.to raise_error(ArgumentError, /wrap:, passes:, and noise: are for/)

      wash = plain.looped.stretch(2, mode: :paul).data(0)
      step, inside = wrap_step(wash)
      expect(step).to be < inside
      expect(rms(wash) / rms(held)).to be_within(0.1).of(1)
    end

    it 'follows the sample\'s loop unless told' do
      expect(plain).not_to be_whole_loop
      expect(plain.looped).to be_whole_loop
      expect(plain.looped(0.1..0.5)).not_to be_whole_loop
      expect(plain.stretch(0.77, mode: :spectral).data(0)).to eq(plain.stretch(0.77, mode: :spectral, wrap: false).data(0))
      expect(plain.stretch(0.77, mode: :spectral, wrap: true).data(0)).to eq(plain.looped.stretch(0.77, mode: :spectral).data(0))
      expect(plain.stretch(0.77, mode: :spectral, wrap: true).lineage[3]).to eq({ mode: :spectral, wrap: true })
      expect { plain.stretch(0.77, wrap: true) }.to raise_error(ArgumentError, /wrap:, passes:, and noise: are for/)
      expect { plain.stretch(0.77, mode: :slice, wrap: true) }.to raise_error(ArgumentError, /wrap:, passes:, and noise: are for/)
      expect { plain.stretch(0.77, mode: :spectral, wrap: 1) }.to raise_error(ArgumentError, /wrap: is true/)
    end

    it 'keeps a hit at the loop start, and hears no attack where a held sound wraps' do
      x = held * 0.3
      x[0...2400] += Numo::NMath.sin(Numo::DFloat.new(2400).seq * 0.9) * Numo::NMath.exp(-Numo::DFloat.new(2400).seq / 300.0) * 0.6
      hit = MB::Sound::Sample[Numo::SFloat.cast(x)].looped
      expect(hit.onsets(wrap: true)).to eq([0])
      # (a pad that starts loud has an onset at 0 only when nothing
      # comes before it)
      expect(plain.onsets).to eq([0])
      expect(plain.onsets(wrap: true)).to eq([])
      new = Numo::DFloat.cast(hit.stretch(1.25, mode: :spectral).data(0))
      # The hit is the input's, and so is what leads into it
      expect((new[0...240] - x[0...240]).abs.max).to be < 0.005
      expect((new[-240..] - x[-240..]).abs.max).to be < 0.005

      # Paulstretch keeps it on the loop point (its own edges: read in a
      # circle, the random phases also played it up to 125 ms early)
      wash = Numo::DFloat.cast(hit.stretch(2, mode: :paul).data(0))
      expect(wash).to eq(Numo::DFloat.cast(hit.stretch(2, mode: :paul, wrap: false).data(0)))
      expect(Numo::DFloat.cast(hit.stretch(2, mode: :paul, wrap: true).data(0))).to eq(wash)
      circle = MB::Sound::Sample::Spectral.looped(hit.to_a, 2, window: 12000, randomize: 1)[0]
      expect(rms(wash[0...960]) / rms(wash[-960..])).to be > 2
      expect(rms(circle[0...960]) / rms(circle[-960..])).to be < 1.5
      # (a pad held through the loop point is still read in a circle)
      expect(plain.looped.stretch(2, mode: :paul).data(0)).not_to eq(plain.stretch(2, mode: :paul, wrap: false).data(0))
    end

    it 'stretches for loop players as a loop' do
      player = MB::Sound::GraphNode::LoopPlayer
      expect(player.loop_stretch({ mode: :spectral })).to eq({ mode: :spectral, wrap: true })
      expect(player.loop_stretch({ mode: :pv, transients: false })).to eq({ mode: :pv, transients: false, wrap: true })
      expect(player.loop_stretch({ mode: :spectral, wrap: false })).to eq({ mode: :spectral, wrap: false })
      expect(player.loop_stretch({ mode: :slice })).to eq({ mode: :slice })
      expect(player.loop_stretch({})).to eq({})
      # (a sample with no loop points, played as a loop a fifth slower)
      loop = MB::Sound::Sample[Numo::SFloat.cast(held), bpm: 150, beats: 2.5]
      played = loop.follow(stretch: :spectral).sample(60000).dup
      expect(played).to eq(loop.stretch(1.25, mode: :spectral, wrap: true).data(0))
      expect(played).not_to eq(loop.stretch(1.25, mode: :spectral).data(0))
      expect(loop.follow(stretch: { mode: :spectral, wrap: false }).sample(60000)).to eq(loop.stretch(1.25, mode: :spectral).data(0))
    end
  end

  describe MB::Sound::Sample::Spectral::Stream do
    let(:held) {
      i = Numo::DFloat.new(48000).seq / 48000
      (Numo::NMath.sin(i * (2 * Math::PI * 110)) * 0.3 + Numo::NMath.sin(i * (2 * Math::PI * 165) + 1) * 0.2 + Numo::NMath.sin(i * (2 * Math::PI * 331) + 2) * 0.1) *
        (0.8 + 0.2 * Numo::NMath.cos(i * (2 * Math::PI * 2)))
    }

    # +seconds+ of a stream of +stream+ at +ratio+ in buffers of +size+,
    # per channel
    def run(stream, ratio, seconds, size)
      total = (48000 * seconds).round
      step = 1.0 / (48000 * ratio)
      out = Array.new(stream.channels) { Numo::DFloat.zeros(total) }
      pos = 0
      while pos < total
        count = [size, total - pos].min
        phases = (Numo::DFloat.new(count).seq + pos) * step
        phases -= phases.floor
        stream.channels.times { |ch| out[ch][pos...(pos + count)] = stream.pull(ch, phases, step) }
        pos += count
      end
      out
    end

    it 'stretches a loop as it plays: no wrap to hear, the level kept, the same at any buffer size' do
      [0.77, 1.25].each do |r|
        y = run(described_class.new([held]), r, 3.2, 800)[0]
        expect(rms(y) / rms(held)).to be_within(0.02).of(1)
        expect((y[1..] - y[0...-1]).abs.max).to be < 1.1 * (held[1..] - held[0...-1]).abs.max
        expect(peak_hz(y)).to be_within(6).of(110)
        expect(run(described_class.new([held]), r, 3.2, 367)[0]).to eq(y)
      end
    end

    it 'turns the channels together and keeps a hit at the loop start' do
      # (a quiet pad under the hit: a stream's held partials come round
      # with other phases each pass, its attacks with the input's)
      x = held * 0.02
      x[0...2400] += Numo::NMath.sin(Numo::DFloat.new(2400).seq * 0.9) * Numo::NMath.exp(-Numo::DFloat.new(2400).seq / 300.0) * 0.6
      l, r = run(described_class.new([x, x * 0.5], onsets: [0]), 1.25, 3, 800)
      expect((r - l * 0.5).abs.max).to be < 1e-9
      # (the second and third time round: the hit as it is in the input)
      [60000, 120000].each { |q| expect((l[q...(q + 240)] - x[0...240]).abs.max).to be < 0.04 }
    end

    it 'follows tempo ramps and jumps without clicks' do
      stream = described_class.new([held])
      phase = 0.0
      out = []
      step = 0.0
      150.times do |b|
        phases = Numo::DFloat.zeros(800)
        800.times do |k|
          t = (b * 800 + k) / 48000.0
          step = 1.0 / (48000 * (0.77 + 0.24 * [t, 2].min))
          phases[k] = phase % 1.0
          phase += step
        end
        phase += 0.37 if b == 120
        out << stream.pull(0, phases, step).dup
      end
      y = SpecBuffers.join(out)
      expect(y.isnan.any?).to be(false)
      expect((y[1..] - y[0...-1]).abs.max).to be < 1.5 * (held[1..] - held[0...-1]).abs.max
      [0...48000, 48000...96000, 100000...120000].each { |range| expect(rms(y[range]) / rms(held)).to be_within(0.1).of(1) }
    end

    it 'plays under follow with live: true' do
      loop = MB::Sound::Sample[[Numo::SFloat.cast(held), Numo::SFloat.cast(held * 0.5)], bpm: 150, beats: 2.5]
      node = loop.follow(stretch: { mode: :spectral, live: true })
      expect(node[0].to_s).to include('spectral stretch, live')
      l = node[0].sample(800).dup
      r = node[1].sample(800).dup
      want = run(loop.spectral_stream, 1.25, 800 / 48000.0, 800)
      expect(l).to eq(Numo::SFloat.cast(want[0]))
      expect(r).to eq(Numo::SFloat.cast(want[1]))
      expect { loop.follow(stretch: { mode: :slice, live: true }) }.to raise_error(ArgumentError, /live: follows with the phase vocoder/)
      expect { loop.follow(stretch: { mode: :spectral, live: true, randomize: 0.5 }) }.to raise_error(ArgumentError, /live: follows with the phase vocoder/)
      expect { MB::Sound::GraphNode::LoopPlayer.new(loop, stretch: { mode: :spectral, live: true }) }.to raise_error(ArgumentError, /needs the stream/)
    end
  end

  it 'takes an amount for transients: how much around each onset stays unstretched' do
    # (four bursts over a quiet chord)
    x = chord * 0.1
    [3000, 9000, 15000, 21000].each { |h| x[h...(h + 1500)] += Numo::NMath.sin(Numo::DFloat.new(1500).seq * 0.9) * Numo::NMath.exp(-Numo::DFloat.new(1500).seq / 200.0) * 0.6 }
    hits = MB::Sound::Sample[x]
    on = hits.onsets
    expect(on).to eq([3001, 9001, 15001, 21001])
    half = hits.stretch(4, mode: :spectral, transients: 0.5)
    expect(Numo::DFloat.cast(half.data(0))).to eq(Numo::DFloat.cast(Numo::SFloat.cast(described_class.vocoder([Numo::DFloat.cast(hits.data(0))], 4.0, onsets: on, span: 0.5)[0])))
    expect(half.lineage[3]).to eq({ mode: :spectral, transients: 0.5 })
    expect(hits.stretch(4, mode: :spectral, transients: 1)).to equal(hits.stretch(4, mode: :spectral))
    expect(hits.stretch(4, mode: :spectral, transients: 0)).to equal(hits.stretch(4, mode: :spectral, transients: false))

    # Half the span: every hit still lands on its stretched time, and
    # more of the sound between hits shares the stretch (the map between
    # the first two hits is nearer 4x)
    full_map, = described_class.time_map(24000, 4.0, on, 4096, 1024)
    half_map, = described_class.time_map(24000, 4.0, on, 4096, 1024, 0.5)
    on.each { |o| expect(half_map.call(o * 4.0)).to be_within(1e-6).of(o) }
    slope = ->(map) { (map.call(4 * 6000 + 1024) - map.call(4 * 6000)) / 1024.0 }
    expect(1 / slope.call(full_map)).to be > 1 / slope.call(half_map)
    expect(1 / slope.call(half_map)).to be_between(4, 7)
    [2, -0.1, :some].each { |bad| expect { hits.stretch(4, mode: :spectral, transients: bad) }.to raise_error(ArgumentError, /transients: is true, false, or an amount/) }

    # Random phases with transients: the hits stay hits in the
    # vocoder's window (Paulstretch's wash alone has none; its quarter-
    # second window keeps only hits that are further apart than these)
    q = 4 * 9000
    step = ->(d) { rms(d[q...(q + 480)]) / (rms(d[(q - 480)...q]) + 1e-9) }
    expect(step.call(hits.stretch(4, mode: :spectral, randomize: 0.6).data(0))).to be > 4
    expect(step.call(hits.stretch(4, mode: :spectral, randomize: 1).data(0))).to be > 4
    expect(step.call(hits.stretch(4, mode: :paul).data(0))).to be < 2
  end

  describe 'noise:' do
    # How alike the sound is to itself +lag+ samples later, tones taken
    # out: the autocorrelation of 16384-sample frames whose spectra are
    # divided by their own smoothed level, at +lag+ (re lag 0)
    def self_similarity(d, lag)
      d = Numo::DFloat.cast(d)
      w = MB::Sound::Sample::Spectral.hann(16384)
      power = Numo::DFloat.zeros(8193)
      (0..(d.length - 16384)).step(8192) do |from|
        p2 = Numo::Pocketfft.rfft(d[from...(from + 16384)] * w).abs**2
        c = Numo::DFloat.zeros(8194)
        c[1..] = p2.cumsum
        idx = Numo::Int64.new(8193).seq
        lo = (idx - 32).clip(0, 8193)
        hi = (idx + 32).clip(0, 8193)
        power += p2 / ((c[hi] - c[lo]) / Numo::DFloat.cast(hi - lo) + 1e-20)
      end
      acf = Numo::Pocketfft.irfft(Numo::DComplex.cast(power))
      acf[(lag - 2)..(lag + 2)].max / acf[0]
    end

    let(:hiss) { Numo::NArray.srand(11); Numo::DFloat.new(96000).rand(-0.5, 0.5) }
    let(:tones) {
      i = Numo::DFloat.new(96000).seq / 48000
      (Numo::NMath.sin(i * (2 * Math::PI * 220)) + Numo::NMath.sin(i * (2 * Math::PI * 277.2)) + Numo::NMath.sin(i * (2 * Math::PI * 329.6))) * 0.2
    }

    it 'keeps the vocoder\'s window from sounding in stretched noise, and the noise\'s level' do
      smp = MB::Sound::Sample[Numo::SFloat.cast(hiss)]
      expect(self_similarity(hiss, 4096)).to be < 0.03
      # (every bin held as a partial on a grid of 48000 / 4096 Hz: the
      # stretch repeats itself a window later, and the more the longer
      # the stretch; more overlap or another window only moves it)
      plain = smp.stretch(8, mode: :spectral, transients: false)
      expect(self_similarity(plain.data(0), 4096)).to be > 0.12
      expect(self_similarity(smp.stretch(8, mode: :spectral, transients: false, overlap: 8).data(0), 4096)).to be > 0.12
      expect(self_similarity(smp.stretch(8, mode: :spectral, transients: false, window: 2048).data(0), 2048)).to be > 0.12
      loose = smp.stretch(8, mode: :spectral, transients: false, noise: 1)
      expect(self_similarity(loose.data(0), 4096)).to be < 0.03
      expect(rms(loose.data(0)) / rms(hiss)).to be_within(0.05).of(1)
      expect(rms(plain.data(0)) / rms(hiss)).to be < 0.9
      expect(loose.lineage[3]).to eq({ mode: :spectral, transients: false, noise: 1 })
      expect(smp.stretch(8, mode: :spectral, transients: false, noise: 1, seed: 3).data(0)).not_to eq(loose.data(0))
      expect(smp.stretch(8, mode: :spectral, noise: true)).to equal(smp.stretch(8, mode: :spectral, noise: 1))
      expect(smp.stretch(8, mode: :spectral, noise: 0)).to equal(smp.stretch(8, mode: :spectral))
    end

    it 'leaves partials and attacks alone' do
      # (a chord with hiss 14 dB under it: the partial at 220 Hz stays
      # a line, the hiss stops repeating)
      mix = MB::Sound::Sample[Numo::SFloat.cast(tones + hiss * 0.2)]
      line = ->(d) {
        sp = Numo::Pocketfft.rfft(Numo::DFloat.cast(d)[0...65536] * described_class.hann(65536)).abs**2
        sp[296..305].sum / sp[259..341].sum
      }
      plain = mix.stretch(8, mode: :spectral, transients: false).data(0)
      loose = mix.stretch(8, mode: :spectral, transients: false, noise: 1).data(0)
      expect(line.call(plain)).to be > 0.99
      expect(line.call(loose)).to be > 0.99
      expect(self_similarity(plain, 4096)).to be > 0.12
      expect(self_similarity(loose, 4096)).to be < 0.04
      # (a pure chord is not touched beyond rounding)
      pure = MB::Sound::Sample[Numo::SFloat.cast(tones)]
      expect((Numo::DFloat.cast(pure.stretch(8, mode: :spectral, transients: false, noise: 1).data(0)) - pure.stretch(8, mode: :spectral, transients: false).data(0))[8192...-8192].abs.max).to be < 0.01

      # A burst in hiss: the frames that hold it are not randomized
      x = hiss * 0.05
      x[24000...26000] += Numo::NMath.sin(Numo::DFloat.new(2000).seq * 0.9) * Numo::NMath.exp(-Numo::DFloat.new(2000).seq / 250.0) * 0.6
      hit = MB::Sound::Sample[Numo::SFloat.cast(x)]
      q = 4 * hit.onsets.last
      a = Numo::DFloat.cast(hit.stretch(4, mode: :spectral).data(0))[q...(q + 480)]
      b = Numo::DFloat.cast(hit.stretch(4, mode: :spectral, noise: 1).data(0))[q...(q + 480)]
      expect((a - b).abs.max).to be < 0.02
      expect { hit.stretch(4, mode: :spectral, noise: 2) }.to raise_error(ArgumentError, /noise: is 0..1/)
      expect { hit.stretch(4, noise: 1) }.to raise_error(ArgumentError, /noise: are for mode: :spectral/)
    end

    it 'runs in loops and live streams' do
      smp = MB::Sound::Sample[Numo::SFloat.cast(hiss[0...48000])].looped
      closed = smp.stretch(4, mode: :spectral, noise: 1)
      expect(closed.length).to eq(192000)
      expect(self_similarity(closed.data(0), 4096)).to be < 0.04
      expect(self_similarity(smp.stretch(4, mode: :spectral).data(0), 4096)).to be > 0.05
      stream = smp.spectral_stream(noise: 1)
      step = 1.0 / 192000
      out = Numo::DFloat.zeros(96000)
      120.times { |b| phases = (Numo::DFloat.new(800).seq + b * 800) * step; out[(b * 800)...((b + 1) * 800)] = stream.pull(0, phases - phases.floor, step) }
      expect(self_similarity(out, 4096)).to be < 0.04
      expect(rms(out) / rms(hiss)).to be_within(0.08).of(1)
    end
  end

  it 'raises on bad modes and mixed options' do
    expect { pad.stretch(2, mode: :nope) }.to raise_error(ArgumentError, /mode/)
    expect { pad.stretch(2, window: 2048) }.to raise_error(ArgumentError, /spectral/)
    expect { pad.stretch(-1, mode: :spectral) }.to raise_error(ArgumentError, /positive/)
  end
end
