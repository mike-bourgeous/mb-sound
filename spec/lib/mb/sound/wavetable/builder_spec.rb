RSpec.describe(MB::Sound::Wavetable::Builder) do
  # Amplitudes and phases with the special cases of Complex.polar (zero
  # magnitudes, zero angles, pi, pi / 2) and random values
  let(:rng) { Random.new(5) }
  let(:cases) {
    Array.new(100) {
      n = 1 + rng.rand(40)
      amps = Array.new(2) { Array.new(n) { [0.0, -0.0, rng.rand * 2 - 1, 1.0].sample(random: rng) } }
      phases = Array.new(2) { Array.new(n) { [0.0, -0.0, Math::PI, Math::PI / 2, Math::PI * 1.5, rng.rand * 7 - 3].sample(random: rng) } }
      [amps, phases]
    }
  }

  describe '.spectra_from_harmonics' do
    it 'gives exactly the Ruby mirror (Complex.polar per harmonic)' do
      cases.each do |amps, phases|
        expect(described_class.spectra_from_harmonics(amps, phases).to_binary).to eq(described_class.spectra_from_harmonics_ruby(amps, phases).to_binary)
      end
      expect(described_class.spectra_from_harmonics([0.5, 0.25]).to_binary).to eq(described_class.spectra_from_harmonics_ruby([0.5, 0.25]).to_binary)
      expect(described_class.spectra_from_harmonics([[1.0], [0.5, 0.25, 0.125]]).to_binary).to eq(described_class.spectra_from_harmonics_ruby([[1.0], [0.5, 0.25, 0.125]]).to_binary)
    end

    it 'checks the phases' do
      expect { described_class.spectra_from_harmonics([[1, 2]], [[0]]) }.to raise_error(ArgumentError, /phases/)
      expect { described_class.spectra_from_harmonics([[1], [2]], [[0]]) }.to raise_error(ArgumentError, /frames/)
    end
  end

  describe '.half_means' do
    it 'gives exactly the Ruby mirror' do
      cases.each do |amps, phases|
        spectra = described_class.spectra_from_harmonics(amps, phases)
        spectra[true, 0] = rng.rand
        expect(described_class.half_means(spectra).to_binary).to eq(described_class.half_means_ruby(spectra).to_binary)
      end
    end
  end

  describe '.wrap_guard' do
    it 'wraps each row around by GUARD samples on both sides' do
      guard = MB::Sound::Wavetable::GUARD
      [4, 16, 64].each do |n|
        frames = Numo::SFloat.new(2, n).rand(-1, 1)
        out = described_class.wrap_guard(frames)
        expect(out.shape).to eq([2, n + 2 * guard])
        2.times do |r|
          (-guard...(n + guard)).each { |i| expect(out[r, guard + i]).to eq(frames[r, i % n]) }
        end
      end
    end
  end
end
