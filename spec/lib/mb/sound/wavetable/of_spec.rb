# Wavetable.of and the console's wavetable_of: scan tables from mixed frame
# sources (omnibus9).
RSpec.describe('MB::Sound::Wavetable.of', :aggregate_failures) do
  let(:wt) { MB::Sound::Wavetable }
  let(:cube) { ->(p) { Math.sin(2 * Math::PI * p)**3 } }

  it 'makes one frame per source, every frame of a scan table, in order' do
    t = wt.of(:sine, :saw, [1, 0.5, 0.33], cube, wt[:basic], Numo::SFloat[0, 1, 0, -1])
    expect(t.frame_count).to eq(5 + wt[:basic].frame_count)
    expect(t.size).to eq(2048)
  end

  it 'matches the sources it was given (peak-normalized, DC removed)' do
    t = wt.of(:sine, cube, align: false)
    ph = Numo::DFloat.new(2048).seq / 2048
    sine = Numo::NMath.sin(ph * 2 * Math::PI)
    expect((t.frames[0, true] - sine).abs.max).to be < 1e-5
    c = sine**3
    expect((t.frames[1, true] - c / c.abs.max).abs.max).to be < 1e-5
    expect(t.frames.abs.max(axis: 1).to_a).to all(be_within(1e-5).of(1))
  end

  it 'keeps levels with normalize: nil and evens loudness with :loudness' do
    t = wt.of([0.5], [2], normalize: nil, align: false)
    expect(t.frames.abs.max(axis: 1).to_a.map { |x| x.round(4) }).to eq([0.5, 2.0])
    l = wt.of(:sine, :square, normalize: :loudness)
    expect(l.loudness[1]).to be_within(0.01).of(l.loudness[0])
    expect(l.loudness[0]).to be_within(0.01).of(wt[:saw].loudness[0])
  end

  it 'is band-limited like any table and morphs with scan:' do
    t = wt.of(:sine, :saw)
    lo = 220.hz.wavetable(t, scan: 0).sample(4800).dup
    hi = 220.hz.wavetable(t, scan: 1).sample(4800).dup
    expect(lo.abs.max).to be_within(0.05).of(1)
    expect((hi - lo).abs.max).to be > 0.2
    # 6 kHz saw: no harmonics above Nyquist alias back (energy stays near the multiples)
    top = 6000.hz.wavetable(t, scan: 1).sample(48000).dup
    spectrum = MB::Sound.real_fft(top).abs
    alias_bins = spectrum.to_a.each_with_index.reject { |_, i| i % 6000 == 0 || (i % 6000) < 3 || (i % 6000) > 5997 }.map(&:first)
    expect(alias_bins.max / spectrum.max).to be < 1e-3
  end

  it 'explains sources it does not take' do
    expect { wt.of }.to raise_error(ArgumentError, /at least one frame source/)
    expect { wt.of(Object.new) }.to raise_error(ArgumentError, /source 1 \(Object\).*harmonic amplitudes/)
    expect { wt.of(:sine, [1, :x]) }.to raise_error(ArgumentError, /source 2: an Array is harmonic amplitudes/)
    expect { wt.of(:sine, size: 4) }.to raise_error(ArgumentError, /size:/)
    expect { wt.of(:sine, normalize: :rms) }.to raise_error(ArgumentError, /normalize:/)
    expect { wt.of(:nope) }.to raise_error(ArgumentError, /No wavetable named :nope/)
  end

  describe 'console wavetable_of' do
    it 'prints itself back and saves in graph documents that load the same' do
      t = MB::Sound.wavetable_of(:sine, :saw, [1, 0.5, 0.33], ->(p) { Math.sin(2 * Math::PI * p)**3 }, normalize: :loudness)
      g = 110.hz.wavetable(t, scan: 0.4)
      expect(g.to_ruby).to eq('110.hz.wavetable(wavetable_of(:sine, :saw, [1, 0.5, 0.33], ->(p) { Math.sin(2 * Math::PI * p)**3 }, normalize: :loudness), scan: 0.4)')

      text = MB::Sound::GraphIO.dump(g)
      a = g.sample(4800).dup
      loaded = MB::Sound::GraphIO.load(text)
      expect(loaded.sample(4800)).to eq(a)
    end

    it 'keeps documents within the table size limit' do
      expect { MB::Sound::GraphIO.load('110.hz.wavetable(wavetable_of(:sine, size: 1_000_000))') }.to raise_error(MB::Sound::GraphIO::LoadError, /wavetable_size/)
    end
  end
end
