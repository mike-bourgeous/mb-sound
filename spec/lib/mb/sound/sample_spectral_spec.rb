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
