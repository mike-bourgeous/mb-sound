RSpec.describe(MB::Sound::Sample::Spectral, :aggregate_failures) do
  let(:t) { Numo::DFloat.new(24000).seq / 48000 }
  let(:chord) { Numo::NMath.sin(t * 2 * Math::PI * 220) * 0.4 + Numo::NMath.sin(t * 2 * Math::PI * 330) * 0.3 }
  let(:pad) { MB::Sound::Sample[[chord, chord * 0.5]] }

  # The strongest frequency (Hz) of the middle 8192 samples of +d+.
  def peak_hz(d)
    m = d.length / 2
    seg = Numo::DFloat.cast(d[(m - 4096)...(m + 4096)])
    (Numo::Pocketfft.rfft(seg * described_class.hann(8192)).abs.max_index * 48000.0 / 8192)
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

  it 'raises on bad modes and mixed options' do
    expect { pad.stretch(2, mode: :nope) }.to raise_error(ArgumentError, /mode/)
    expect { pad.stretch(2, window: 2048) }.to raise_error(ArgumentError, /spectral/)
    expect { pad.stretch(-1, mode: :spectral) }.to raise_error(ArgumentError, /positive/)
  end
end
