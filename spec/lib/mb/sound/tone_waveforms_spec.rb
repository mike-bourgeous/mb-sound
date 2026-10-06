# Waveform values and sampling of Tone (formerly the Oscillator specs;
# Oscillator was folded into Tone).
RSpec.describe MB::Sound::Tone do
  [:value_at, :value_at_ruby].each do |method|
    describe ".#{method}" do
      let(:method_name) { method }

      # Calls Tone.value_at(wave, phi) as wave.send(method, phi)
      def wave(type)
        m = method_name
        Struct.new(:type) do
          define_method(:value_at) { |phi| MB::Sound::Tone.value_at(type, phi) }
          define_method(m) { |phi| MB::Sound::Tone.public_send(m, type, phi) }
        end.new(type)
      end

      it 'returns expected sine wave values for given phases' do
        lfo = wave(:sine)
        expect(lfo.send(method, 0).round(6)).to eq(0)
        expect(lfo.send(method, 0.25 * Math::PI).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method, 0.5 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, Math::PI).round(6)).to eq(0)
        expect(lfo.send(method, 1.25 * Math::PI).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method, 1.5 * Math::PI).round(6)).to eq(-1)
      end

      it 'returns expected triangle wave values for given phases' do
        lfo = wave(:triangle)
        expect(lfo.send(method, 0).round(6)).to eq(0)
        expect(lfo.send(method, 0.125 * Math::PI).round(6)).to eq(0.25)
        expect(lfo.send(method, 0.25 * Math::PI).round(6)).to eq(0.5)
        expect(lfo.send(method, 0.5 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, 0.75 * Math::PI).round(6)).to eq(0.5)
        expect(lfo.send(method, Math::PI).round(6)).to eq(0)
        expect(lfo.send(method, 1.25 * Math::PI).round(6)).to eq(-0.5)
        expect(lfo.send(method, 1.5 * Math::PI).round(6)).to eq(-1)
        expect(lfo.send(method, 1.75 * Math::PI).round(6)).to eq(-0.5)
        expect(lfo.send(method, 1.875 * Math::PI).round(6)).to eq(-0.25)
      end

      it 'returns expected ramp wave values for given phases' do
        lfo = wave(:ramp)
        expect(lfo.send(method, 0).round(6)).to eq(0)
        expect(lfo.send(method, 0.125 * Math::PI).round(6)).to eq(0.125)
        expect(lfo.send(method, 0.25 * Math::PI).round(6)).to eq(0.25)
        expect(lfo.send(method, 0.5 * Math::PI).round(6)).to eq(0.5)
        expect(lfo.send(method, 0.75 * Math::PI).round(6)).to eq(0.75)
        expect(lfo.send(method, 0.999 * Math::PI).round(6)).to eq(0.999)
        expect(lfo.send(method, Math::PI).round(6)).to eq(-1)
        expect(lfo.send(method, 1.25 * Math::PI).round(6)).to eq(-0.75)
        expect(lfo.send(method, 1.5 * Math::PI).round(6)).to eq(-0.5)
        expect(lfo.send(method, 1.875 * Math::PI).round(6)).to eq(-0.125)
        expect(lfo.send(method, 1.999 * Math::PI).round(6)).to eq(-0.001)
      end

      it 'returns expected square wave values for given phases' do
        lfo = wave(:square)
        expect(lfo.send(method, 0).round(6)).to eq(1)
        expect(lfo.send(method, 0.125 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, 0.25 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, 0.5 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, 0.75 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, Math::PI).round(6)).to eq(-1)
        expect(lfo.send(method, 1.25 * Math::PI).round(6)).to eq(-1)
        expect(lfo.send(method, 1.5 * Math::PI).round(6)).to eq(-1)
        expect(lfo.send(method, 1.875 * Math::PI).round(6)).to eq(-1)
      end

      it 'returns expected complex sine values' do
        o = wave(:complex_sine)
        expect(MB::M.round(o.send(method, 0), 6)).to eq(0-1i)
        expect(MB::M.round(o.send(method, 45.degrees), 6)).to eq(MB::M.round(CMath.exp(-45i.degrees), 6))
        expect(MB::M.round(o.send(method, 90.degrees), 6)).to eq(1+0i)
        expect(MB::M.round(o.send(method, 180.degrees), 6)).to eq(0+1i)
        expect(MB::M.round(o.send(method, 270.degrees), 6)).to eq(-1+0i)
      end

      it 'returns expected complex square values' do
        o = wave(:complex_square)
        expect(MB::M.round(o.send(method, 45.degrees), 6).real).to eq(1)
        expect(MB::M.round(o.send(method, 45.degrees), 6).imag).to be < 0.25

        expect(MB::M.round(o.send(method, 90.degrees), 6)).to eq(1)

        expect(MB::M.round(o.send(method, 135.degrees), 6).real).to eq(1)
        expect(MB::M.round(o.send(method, 135.degrees), 6).imag).to be > 0.25

        expect(MB::M.round(o.send(method, 225.degrees), 6).real).to eq(-1)
        expect(MB::M.round(o.send(method, 225.degrees), 6).imag).to be > 0.25

        expect(MB::M.round(o.send(method, 270.degrees), 6)).to eq(-1)

        expect(MB::M.round(o.send(method, 315.degrees), 6).real).to eq(-1)
        expect(MB::M.round(o.send(method, 315.degrees), 6).imag).to be < -0.25
      end

      it 'wraps around phase for triangle' do
        o = wave(:triangle)
        expect(MB::M.round(o.send(method, 0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI + 0.1), 6))
        expect(MB::M.round(o.send(method, -0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI - 0.1), 6))
      end

      it 'wraps around phase for gauss' do
        o = wave(:gauss)
        expect(MB::M.round(o.send(method, 0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI + 0.1), 6))
        expect(MB::M.round(o.send(method, -0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI - 0.1), 6))
      end

      it 'wraps around phase for square' do
        o = wave(:square)
        expect(o.send(method, 0.1)).to eq(o.value_at(2*Math::PI + 0.1))
        expect(o.send(method, -0.1)).to eq(o.value_at(2*Math::PI - 0.1))
      end

      it 'wraps around phase for parabola' do
        o = wave(:parabola)
        expect(MB::M.round(o.send(method, 0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI + 0.1), 6))
        expect(MB::M.round(o.send(method, -0.1), 6)).to eq(MB::M.round(o.send(method, 2*Math::PI - 0.1), 6))
      end

      pending 'returns expected gauss values'
      pending 'returns expected parabolic values'
    end
  end

  [:sample, :sample_ruby, :sample_c].each do |method|
    describe "##{method}" do
      # A naive tone at 1 Hz and +rate+ samples per second, so each sample
      # advances by 1 / rate cycles.
      def slow(wave, rate, **opts)
        MB::Sound::Tone.new(wave_type: wave, frequency: 1, sample_rate: rate, **opts).tap { |t| t.send(:set_wave, wave, false) }
      end

      def one(tone, method)
        tone.send(method, 1)[0]
      end

      it 'returns a different value on subsequent calls' do
        lfo = 1.hz.sine
        result = one(lfo, method)
        5.times do
          old_result = result
          result = one(lfo, method)
          expect(result).not_to eq(old_result)
        end
      end

      it 'returns the expected sequence for a faster advancing sine wave' do
        lfo = slow(:sine, 8)
        r = 0.5 ** 0.5
        expect(9.times.map { one(lfo, method).round(6) }).to eq([0, r, 1, r, 0, -r, -1, -r, 0].map { |v| v.round(6) })
      end

      it 'returns the expected sequence for a faster advancing triangle wave' do
        lfo = slow(:triangle, 8)
        expect(9.times.map { one(lfo, method).round(6) }).to eq([0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5, 0])
      end

      it 'scales to a different range' do
        lfo = slow(:triangle, 8).at(2..5)
        expect(9.times.map { one(lfo, method).round(6) }).to eq([3.5, 4.25, 5, 4.25, 3.5, 2.75, 2, 2.75, 3.5])
      end

      it 'takes phase into account' do
        lfo = slow(:square, 10).with_phase(0.9 * Math::PI)
        expect(one(lfo, method)).to eq(1)
        expect(one(lfo, method)).to eq(-1)

        lfo = slow(:square, 2).with_phase(1.5 * Math::PI)
        expect(one(lfo, method)).to eq(-1)
        expect(one(lfo, method)).to eq(1)
      end

      it 'can generate more than one sample' do
        oscil = 100.hz.sine
        data = oscil.send(method, 48000)
        expect(data.length).to eq(48000)
        expect(data.min.round(3)).to eq(-1)
        expect(data.max.round(3)).to eq(1)
        expect(data.sum.round(2)).to eq(0)
      end

      it 'produces expected square wave output for a low sample rate' do
        oscil = 1.hz.asquare.at(0.5).at_rate(50)
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(-0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(-0.5))
      end

      it 'produces expected square wave output for a moderate sample rate' do
        oscil = 1.hz.asquare.at_rate(1600).at(1)
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(-1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(-1))
      end

      it 'matches the analytic signal for a complex sine wave' do
        oscil = 240.hz.complex_sine.at(1)
        result = oscil.send(method, 1600)
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.at(1).sample(1600)))

        expect(MB::M.round(result, 5)).to eq(MB::M.round(target, 5))
      end

      it 'matches the analytic signal for a complex square wave (approximately)' do
        oscil = 240.hz.acomplex_square.at(1)
        result = oscil.send(method, 1600)
        # 240Hz at 48kHz puts square wave transitions exactly on samples, so
        # sample 6400 + i of the reference has the same phase as sample i
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.asquare.at(1).sample(16000))[6400...8000])

        expect(MB::M.round(result.real, 5)).to eq(MB::M.round(target.real, 5))

        delta = result.imag - target.imag
        expect(delta.abs.max).to be < 0.4
        expect(delta.mean.abs).to be < 0.001
        expect(delta.abs.mean).to be < 0.05
      end

      it 'matches the analytic signal for a complex triangle wave (approximately)' do
        oscil = 240.hz.acomplex_triangle.at(1)
        result = oscil.send(method, 1600)
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.atriangle.at(1).sample(16000))[6400...8000])

        expect(MB::M.round(result.real, 6)).to eq(MB::M.round(target.real, 6))

        delta = result.imag - target.imag
        expect(delta.abs.max).to be < 0.005
        expect(delta.mean.abs).to be < 0.0005
        expect(delta.abs.mean).to be < 0.0005
      end

      it 'matches the analytic signal for a complex ramp wave (approximately)' do
        oscil = 240.hz.acomplex_ramp.at(1)
        result = oscil.send(method, 1600)

        base = MB::Sound.analytic_signal(120.hz.aramp.at(1).sample(32000)).reshape(16000, 2)[nil, 1] # shift 240hz by half sample
        target = Numo::SComplex.cast(base)[6400...8000]

        expect(MB::M.round(result.real, 6)).to eq(MB::M.round(target.real, 6))

        delta = result.imag.clip(-1, 1) - target.imag.clip(-1, 1)
        expect(delta.abs.max).to be < 0.05
        expect(delta.mean.abs).to be < 0.0005
        expect(delta.abs.mean).to be < 0.01
      end

      it 'truncates output for short reads on frequency' do
        expect(0.constant.until(0.0001).tone.send(method, 48000)).to eq(Numo::SFloat.zeros(5))
      end

      it 'truncates output for short reads on phase' do
        expect(0.hz.pm(0.constant.until(0.0001)).send(method, 48000)).to eq(Numo::SFloat.zeros(5))
      end

      it 'raises an error if truncation happens twice' do
        a = 0.constant
        expect(a).to receive(:sample).with(10).at_least(2).times.and_return(Numo::SFloat[1,2,3])

        # get_sampler/tee effectively act as a buffer adapter, so we need to
        # break tee wrapping to force direct truncation
        expect(a).to receive(:get_sampler).at_least(1).time.and_return(a)

        osc = 0.hz.pm(a)
        expect(osc.sample(10).length).to eq(3)

        expect { osc.sample(10) }.to raise_error(/Truncation/)
      end

      it 'updates the last_freq value' do
        a = 50.constant(smoothing: false)
        osc = 100.hz.fm(a)
        expect { osc.sample(10) }.to change { osc.last_freq }.to(150)

        a.constant = 15
        expect { osc.sample(10) }.to change { osc.last_freq }.to(115)
      end
    end
  end

  describe '#phi' do
    it 'gives the starting phase before playing, wrapped to 0..2pi' do
      expect(1.hz.with_phase(362.degrees).phi.round(5)).to eq(2.degrees.round(5))
      expect(1.hz.with_phase(-2.degrees).phi.round(5)).to eq(358.degrees.round(5))
    end

    it 'follows the phase while playing' do
      t = MB::Sound::Tone.new(frequency: 1, sample_rate: 4)
      t.sample(1)
      expect(t.phi).to be_within(1e-12).of(Math::PI / 2)
    end
  end

  describe '#state' do
    it 'holds everything that changes from sample to sample' do
      make = -> { 1001.hz.ramp.fm(70.hz.at(80)).reset(MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(173).tap { |t| t[37] = 1 }], repeat: true)).at(0.5) }
      a = make.call
      a.sample(150)

      # A new tone with a copy of a's state plays on exactly like a (its
      # inputs are new, so they restart: read them to the same place)
      b = make.call
      b.sample(150)
      b.instance_variable_set(:@state, MB::Sound::Tone::State.new(**a.state.to_h))
      expect(b.sample(400)).to eq(a.sample(400))
    end
  end
end
