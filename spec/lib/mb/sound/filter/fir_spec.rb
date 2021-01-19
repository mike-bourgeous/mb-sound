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

  let (:freq_filter) {
    MB::Sound::Filter::FIR.new(
      Numo::DFloat.linspace(1.0, 0.0, 65)
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

    context 'when given a Numo::NArray' do
      it 'can initialize a filter with frequency-domain coefficients' do
        expect(freq_filter.gain_map).to be_nil
        expect(freq_filter.gains.length).to eq(65)
        expect(freq_filter.impulse.length).to eq(128)
        expect(freq_filter.gains.length).to be < freq_filter.filter_fft.length
      end

      it 'has expected gain at DC' do
        expect(freq_filter.gains[0].abs.round(4)).to eq(1)
        expect(freq_filter.filter_fft[0].abs.round(4)).to eq(1)
      end

      it 'has the expected gain in the middle of the spectrum' do
        expect(freq_filter.gains[freq_filter.gains.length / 2].abs.round(4)).to eq(0.5)
        expect(freq_filter.filter_fft[freq_filter.filter_fft.length / 2].abs.round(4)).to eq(0.5)
      end

      it 'has the expected gain near Nyquist' do
        expect(freq_filter.gains[-1].abs.round(4)).to eq(0)
        expect(freq_filter.filter_fft[-1].abs.round(4)).to eq(0)
      end
    end
  end

  describe '#process' do
    let(:noise) {
      Numo::SFloat.zeros(20000).rand(-1, 1)
    }

    let(:delay) {
      process_delay = unity_filter.window_length - (unity_filter.filter_length - 1) # TODO: add a delay accessor
      impulse_delay = unity_filter.filter_length / 2 - 1
      process_delay + impulse_delay
    }

    let(:padded_noise) {
      noise.concatenate(Numo::SFloat.zeros(delay))
    }

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

    it 'preserves a long signal exactly through a unity gain filter' do
      result = unity_filter.process(padded_noise)[delay..-1]
      expect(MB::Sound::M.round(result, 5)).to eq(MB::Sound::M.round(noise, 5))
    end

    it 'preserves a signal sent one sample at a time' do
      result = Numo::SFloat.zeros(noise.length)
      padded_noise.each_with_index do |v, idx|
        o = unity_filter.process(v)[0]
        result[idx - delay] = o if idx >= delay
      end
      expect(MB::Sound::M.round(result, 5)).to eq(MB::Sound::M.round(noise, 5))
    end
  end

  describe '#response' do
    it 'returns frequency response from the padded FFT' do
      expect(freq_filter.response(0)).to eq(freq_filter.filter_fft[0])
      expect(freq_filter.response(Math::PI)).to eq(freq_filter.filter_fft[-1])
      expect(freq_filter.response(Math::PI / 2)).to eq(freq_filter.filter_fft[freq_filter.filter_fft.length / 2])
      expect(freq_filter.response(-Math::PI / 2)).to eq(freq_filter.filter_fft[freq_filter.filter_fft.length / 2].conj)
    end
  end

  describe '#reset' do
    it 'can reset to 0' do
      noise = Numo::SFloat.zeros(20000).rand(-1, 1)
      real_filter.process(noise)
      real_filter.reset(0)
      expect(real_filter.process(Numo::SFloat.zeros(20000))).to eq(Numo::SFloat.zeros(20000))
    end

    [0.5, -0.75].each do |v|
      it "can reset to #{v}" do
        # Processing significantly more data than the internal buffer should
        # ensure that we see any glitches that might occur anywhere in that
        # buffer, e.g. because the overlap-add portion is not handled right.
        noise = Numo::SFloat.zeros(20000).rand(-1, 1)
        real_filter.process(noise)
        real_filter.reset(v)

        result = MB::Sound::M.round(real_filter.process(Numo::DFloat.zeros(20000).fill(v)), 3)
        expected = Numo::SFloat.zeros(20000).fill((v * real_filter.filter_fft[0].real).round(3))
        expect(result.min).to eq(expected.min)
        expect(result.max).to eq(expected.max)
        expect(result).to eq(expected)
      end
    end
  end
end
