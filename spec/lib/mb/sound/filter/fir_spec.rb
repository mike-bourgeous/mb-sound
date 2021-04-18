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
        expect(MB::M.round(complex_filter.gains[complex_filter.gains.length / 2], 4)).to eq(0+1i)

        # Have to re-rotate the impulse to compensate for delay so that the impulse peak is at t=0
        # Could also compute and subtract the linear phase in the frequency domain instead
        long_impulse = MB::Sound.real_ifft(complex_filter.filter_fft)
        long_impulse = MB::M.rol(long_impulse, complex_filter.filter_length / 2)
        imp_fft = MB::Sound.real_fft(long_impulse)
        expect(MB::M.round(imp_fft[imp_fft.length / 2], 2)).to eq(0+1i)
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

  context 'delay accessors' do
    [:unity_filter, :freq_filter, :complex_filter, :real_filter].each do |f|
      let(:filter) { send(f) }
      let(:process_delay) { filter.window_length - (filter.filter_length - 1) }
      let(:impulse_delay) { filter.impulse.max_index }
      describe '#delay' do
        it "has the expected value for #{f}" do
          expect(filter.delay).to eq(process_delay + impulse_delay)
        end
      end

      describe '#impulse_delay' do
        it "has the expected value for #{f}" do
          expect(filter.impulse_delay).to eq(impulse_delay)
        end
      end

      describe '#processing_delay' do
        it "has the expected value for #{f}" do
          expect(filter.processing_delay).to eq(process_delay)
        end
      end
    end
  end

  describe '#process' do
    let(:noise) {
      Numo::SFloat.zeros(20000).rand(-1, 1)
    }

    let(:padded_noise) {
      noise.concatenate(Numo::SFloat.zeros(unity_filter.delay))
    }

    it 'has unity gain for a pass-through filter' do
      unity_filter.process(Numo::SFloat.ones(unity_filter.window_length * 10))
      expect(MB::M.round(unity_filter.process(Numo::SFloat.ones(300)), 4)).to eq(Numo::SFloat.ones(300))
    end

    it 'accepts arbitrary length buffers to process' do
      real_filter.process(Numo::SFloat.ones(real_filter.window_length + real_filter.filter_length))
      expect(MB::M.round(real_filter.process(Numo::SFloat.ones(10)), 4)).to eq(Numo::SFloat.ones(10) * real_filter.filter_fft[0].real.round(4))
      expect(MB::M.round(real_filter.process(Numo::SFloat.ones(17)), 4)).to eq(Numo::SFloat.ones(17) * real_filter.filter_fft[0].real.round(4))
      expect(MB::M.round(real_filter.process(Numo::SFloat.ones(1)), 4)).to eq(Numo::SFloat.ones(1) * real_filter.filter_fft[0].real.round(4))
    end

    it 'preserves a long signal exactly through a unity gain filter' do
      result = unity_filter.process(padded_noise)[unity_filter.delay..-1]
      expect(MB::M.round(result, 5)).to eq(MB::M.round(noise, 5))
    end

    it 'preserves a signal sent one sample at a time' do
      result = Numo::SFloat.zeros(noise.length)
      padded_noise.each_with_index do |v, idx|
        o = unity_filter.process(v)[0]
        result[idx - unity_filter.delay] = o if idx >= unity_filter.delay
      end
      expect(MB::M.round(result, 5)).to eq(MB::M.round(noise, 5))
    end
  end

  describe '#response' do
    it 'returns frequency response from the padded FFT at 0' do
      expect(freq_filter.response(0)).to eq(freq_filter.filter_fft[0])
    end

    it 'returns frequency response from the padded FFT at pi' do
      expect(freq_filter.response(Math::PI)).to eq(freq_filter.filter_fft[-1])
    end

    it 'returns frequency response from the padded FFT at pi/2' do
      expect(freq_filter.response(Math::PI / 2)).to eq(freq_filter.filter_fft[freq_filter.filter_fft.length / 2])
    end

    it 'returns frequency response from the padded FFT at -pi/2' do
      expect(freq_filter.response(-Math::PI / 2)).to eq(freq_filter.filter_fft[freq_filter.filter_fft.length / 2].conj)
    end

    it 'interpolates between fft values' do
      omega = 1.0
      idx = (omega * (real_filter.filter_fft.length - 1) / Math::PI).floor
      g1 = real_filter.filter_fft[idx]
      g2 = real_filter.filter_fft[idx + 1]
      r = real_filter.response(omega)
      expect(r).not_to eq(g1)
      expect(r).not_to eq(g2)
      expect(r.real).to be_between(*[g1.real, g2.real].sort)
      expect(r.imag).to be_between(*[g1.imag, g2.imag].sort)
    end

    it 'accepts an NArray for calculating response' do
      input = Numo::SFloat[0, Math::PI, Math::PI / 2, -Math::PI / 2]
      output = Numo::DComplex[
        freq_filter.filter_fft[0],
        freq_filter.filter_fft[-1],
        freq_filter.filter_fft[freq_filter.filter_fft.length / 2],
        freq_filter.filter_fft[freq_filter.filter_fft.length / 2].conj,
      ]

      expect(MB::M.round(freq_filter.response(input), 5)).to eq(MB::M.round(output, 5))
    end
  end

  describe '#reset' do
    [0, 0.5, -0.75].each do |v|
      it "returns the steady-state output for #{v}" do
        expect(real_filter.reset(v).round(6)).to eq((v * real_filter.filter_fft[0].real).round(6))
      end

      it "can reset to #{v}" do
        # Processing significantly more data than the internal buffer should
        # ensure that we see any glitches that might occur anywhere in that
        # buffer, e.g. because the overlap-add portion is not handled right.
        noise = Numo::SFloat.zeros(20000).rand(-1, 1)
        real_filter.process(noise)
        real_filter.reset(v)

        result = MB::M.round(real_filter.process(Numo::DFloat.zeros(20000).fill(v)), 3)
        expected = Numo::SFloat.zeros(20000).fill((v * real_filter.filter_fft[0].real).round(3))
        expect(result.min).to eq(expected.min)
        expect(result.max).to eq(expected.max)
        expect(result).to eq(expected)
      end
    end
  end
end
