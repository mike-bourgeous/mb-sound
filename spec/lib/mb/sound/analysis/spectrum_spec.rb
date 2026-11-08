# Analysis::Spectrum's band levels and tilt as class methods (shared with
# bar statistics, which read each beat's spectrum with them).
RSpec.describe(MB::Sound::Analysis::Spectrum, :aggregate_failures) do
  it 'sums each band\'s bins through its band map' do
    power = Numo::DFloat.new(4097).rand
    kept, map = described_class.band_map(8192, 48000)
    expect(map.shape).to eq([4097, kept.length])
    f = MB::Sound::Analysis::STFT.bin_freqs(8192, 48000)
    levels = described_class.band_levels(power, 48000)
    kept.each_with_index do |c, i|
      sel = (f.ge(c * 2**(-1 / 6.0)) & f.lt(c * 2**(1 / 6.0))).where
      expect(levels[c]).to be_within(1e-9).of(10 * Math.log10(power[sel].sum / power.sum))
    end
  end

  it 'gives about the same tilt from octaves as from third octaves' do
    f = MB::Sound::Analysis::STFT.bin_freqs(8192, 48000)
    pink = 1.0 / f.clip(1, nil) # equal power per octave: tilt 0
    tilted = pink * (f.clip(1, nil) / 1000.0)**(-0.5) # -1.5 dB/octave
    [pink, tilted].zip([0.0, -1.505]).each do |power, tilt|
      thirds = described_class.tilt_of(described_class.band_levels(power, 48000))
      octaves = described_class.tilt_of(described_class.band_levels(power, 48000, centers: described_class::OCTAVE_CENTERS, per_octave: 1))
      expect(thirds).to be_within(0.05).of(tilt)
      expect(octaves).to be_within(0.15).of(thirds)
    end
  end
end
