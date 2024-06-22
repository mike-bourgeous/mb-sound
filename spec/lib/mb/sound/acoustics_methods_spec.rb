RSpec.describe(MB::Sound::AcousticsMethods, aggregate_failures: true) do
  describe '#rt60' do
    [:analytic, :peak_envelope, :regression].each do |mode|
      context "when :mode is #{mode}" do
        it 'returns RT60 for a decaying sine' do
          # FIXME: want to be able to omit the oscillation and get RT60 for an envelope too
          data = 123.hz.sample(48000) * Numo::SFloat.logspace(0, -4, 48000)
          expect(MB::Sound.rt60(data, mode: mode)).to be_within(0.01).of(0.75)
        end
      end
    end
  end

  describe '#peak_list' do
    it 'can return a list of peaks for a trivial input' do
      data = Numo::SFloat[0, 1, 0, -1, 0]
      expect(MB::Sound.peak_list(data)).to eq([{ index: 1, value: 1 }, { index: 3, value: -1 }])
    end

    it 'can return peaks in a slightly more varied input' do
      data = Numo::SFloat[0, -1, -1.125, -0.9, 0, 1.5, 1, 0]
      expect(MB::Sound.peak_list(data)).to eq([{ index: 2, value: -1.125 }, { index: 5, value: 1.5 }])
    end

    it 'returns a peak that occurs after the last zero crossing' do
      data = Numo::SFloat[0, 1, 0, -1, 0, 0.5, 1, 0.25]
      expect(MB::Sound.peak_list(data)).to eq([
        { index: 1, value: 1 },
        { index: 3, value: -1 },
        { index: 6, value: 1 },
      ])
    end

    it 'returns a peak that occurs at the very end' do
      data = Numo::SFloat[0, 1, 0, -1, 0, 0.5, 1]
      expect(MB::Sound.peak_list(data)).to eq([
        { index: 1, value: 1 },
        { index: 3, value: -1 },
        { index: 6, value: 1 },
      ])
    end

    it 'can identify peaks without zeroes bewteen' do
      data = Numo::SFloat[1, -1, 0.5, -0.5]
      expect(MB::Sound.peak_list(data)).to eq([
        { index: 0, value: 1 },
        { index: 1, value: -1 },
        { index: 2, value: 0.5 },
        { index: 3, value: -0.5 },
      ])
    end

    it 'does not count a leading zero as a peak if the first peak is negative' do
      data = Numo::SFloat[0, -1, 0, 1, 0]
      expect(MB::Sound.peak_list(data)).to eq([{ index: 1, value: -1 }, { index: 3, value: 1 }])
    end

    it 'returns a single positive peak if all values are positive' do
      data = Numo::SFloat[1, 2, 3, 2, 1]
      expect(MB::Sound.peak_list(data)).to eq([{ index: 2, value: 3 }])
    end

    it 'returns a single negative peak if all values are negative' do
      data = Numo::SFloat[-1, -2, -2.5, -3, -1]
      expect(MB::Sound.peak_list(data)).to eq([{ index: 3, value: -3 }])
    end
  end

  describe '#monotonic_peak_list' do
    it 'filters peaks to a monotonic rise and fall' do
      data = Numo::SFloat[0.75, -0.125, -0.5, 3, -0.5, 2, -0.5, 4, -0.5, 3, -0.5, 1, -0.5, -1.25, 0.5, -0.25, 0.5]
      expect(MB::Sound.monotonic_peak_list(data)).to eq([
        { index: 2, value: -0.5 },
        { index: 3, value: 3.0 },
        { index: 7, value: 4.0 },
        { index: 9, value: 3.0 },
        { index: 13, value: -1.25 },
        { index: 14, value: 0.5 },
        { index: 15, value: -0.25 },
      ])
    end
  end

  describe '#peak_envelope' do
    it 'returns expected envelope for very simple data' do
      data = Numo::SFloat[-1, 1, -1, 1]
      expect(MB::Sound.peak_envelope(data)).to eq(Numo::SFloat[1, 1, 1, 1])
    end

    it 'skips negative peaks if requested' do
      data = Numo::SFloat[-1, 1, -3, 1]
      expect(MB::Sound.peak_envelope(data, include_negative: false)).to eq(Numo::SFloat[1, 1, 1, 1]) # XXX true
    end
  end
end
