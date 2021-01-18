RSpec.describe MB::Sound::Filter::FIR do
  let (:real_filter) {
    MB::Sound::Filter::FIR.new({
      100 => -10.db,
      500 => -10.db,
      1000 => 0.db,
      3000 => -10.db,
      5000 => 0.db,
      10000 => -10.db,
      15000 => 0.db,
      16000 => -2.db
    })
  }

  let (:complex_filter) {
    MB::Sound::Filter::FIR.new({
      100.hz => 0+1i,
      500.0 => 0+1i,
    })
  }

  let (:unity_filter) {
    MB::Sound::Filter::FIR.new(
      {
        100 => 1,
        200 => 1,
      },
      filter_length: 1000
    )
  }

  describe '#initialize' do
    context 'when given a Hash' do
      it 'can design a filter from a Hash' do
        expect(real_filter.gain_map.length).to eq(10)
        expect(complex_filter.gain_map.length).to eq(4)
        expect(unity_filter.gain_map.length).to eq(4)
      end

      it 'has the expected extrapolated gain at DC' do
        expect(real_filter.gains[0].abs.round(4)).to eq(-10.db.round(4))
        expect(real_filter.filter_fft[0].abs.round(2)).to eq(-10.db.round(2))
      end

      it 'has the expected extrapolated gain at Nyquist' do
        expect(real_filter.gains[-1].abs.round(4)).to be < -2.db.round(4)
        expect(real_filter.filter_fft[-1].abs.round(3)).to be < -2.db.round(3)
      end

      it 'accepts complex gains' do
        expect(MB::Sound::M.round(complex_filter.gains[complex_filter.gains.length / 2], 4)).to eq(0+1i)

        # Have to re-rotate the impulse to compensate for delay so that the impulse peak is at t=0
        # Could also compute and subtract the linear phase in the frequency domain instead
        long_impulse = MB::Sound.real_ifft(complex_filter.filter_fft)
        long_impulse = MB::Sound::A.rol(long_impulse, complex_filter.filter_length / 2 - 1)
        imp_fft = MB::Sound.real_fft(long_impulse)
        expect(MB::Sound::M.round(imp_fft[imp_fft.length / 2], 2)).to eq(0+1i)
      end
    end

    pending 'when given a Numo::NArray'
  end

  describe '#process' do
    it 'has unity gain for a pass-through filter' do
      unity_filter.process(Numo::SFloat.ones(unity_filter.window_length * 10))
      expect(MB::Sound::M.round(unity_filter.process(Numo::SFloat.ones(300)), 4)).to eq(Numo::SFloat.ones(300))
    end

    it 'accepts arbitrary length buffers to process' do
      real_filter.process(Numo::SFloat.ones(real_filter.window_length + real_filter.filter_length))
      expect(MB::Sound::M.round(real_filter.process(Numo::SFloat.ones(10)), 4)).to eq(Numo::SFloat.ones(10) * real_filter.filter_fft[0].real.round(4))
      expect(MB::Sound::M.round(real_filter.process(Numo::SFloat.ones(17)), 4)).to eq(Numo::SFloat.ones(17) * real_filter.filter_fft[0].real.round(4))
      expect(MB::Sound::M.round(real_filter.process(Numo::SFloat.ones(1)), 4)).to eq(Numo::SFloat.ones(1) * real_filter.filter_fft[0].real.round(4))
    end
  end

  pending '#reset'
end
