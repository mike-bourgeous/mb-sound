RSpec.describe MB::Sound::Oscillator do
  [:value_at, :value_at_c, :value_at_ruby].each do |method|
    describe "##{method}" do
      it 'returns expected sine wave values for given phases' do
        lfo = MB::Sound::Oscillator.new(:sine)
        expect(lfo.send(method, 0).round(6)).to eq(0)
        expect(lfo.send(method, 0.25 * Math::PI).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method, 0.5 * Math::PI).round(6)).to eq(1)
        expect(lfo.send(method, Math::PI).round(6)).to eq(0)
        expect(lfo.send(method, 1.25 * Math::PI).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method, 1.5 * Math::PI).round(6)).to eq(-1)
      end

      it 'returns expected triangle wave values for given phases' do
        lfo = MB::Sound::Oscillator.new(:triangle)
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
        lfo = MB::Sound::Oscillator.new(:ramp)
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
        lfo = MB::Sound::Oscillator.new(:square)
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
        o = MB::Sound::Oscillator.new(:complex_sine)
        expect(MB::M.round(o.send(method, 0), 6)).to eq(0-1i)
        expect(MB::M.round(o.send(method, 45.degrees), 6)).to eq(MB::M.round(CMath.exp(-45i.degrees), 6))
        expect(MB::M.round(o.send(method, 90.degrees), 6)).to eq(1+0i)
        expect(MB::M.round(o.send(method, 180.degrees), 6)).to eq(0+1i)
        expect(MB::M.round(o.send(method, 270.degrees), 6)).to eq(-1+0i)
      end

      it 'returns expected complex square values' do
        o = MB::Sound::Oscillator.new(:complex_square)
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

      pending 'returns expected gauss values'
      pending 'returns expected parabolic values'
    end
  end

  [:sample, :sample_ruby, :sample_c].each do |method|
    describe "##{method}" do
      it 'returns a different value on subsequent calls' do
        lfo = MB::Sound::Oscillator.new(:sine)
        result = lfo.sample
        5.times do
          old_result = result
          result = lfo.sample
          expect(result).not_to eq(old_result)
        end
      end

      it 'returns the expected sequence for a faster advancing sine wave' do
        lfo = MB::Sound::Oscillator.new(:sine, advance: 0.25 * Math::PI)
        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(1)
        expect(lfo.send(method).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-1)
        expect(lfo.send(method).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(0)
      end

      it 'returns the expected sequence for a faster advancing triangle wave' do
        lfo = MB::Sound::Oscillator.new(:triangle, advance: 0.25 * Math::PI)
        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq(0.5)
        expect(lfo.send(method).round(6)).to eq(1)
        expect(lfo.send(method).round(6)).to eq(0.5)
        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq(-0.5)
        expect(lfo.send(method).round(6)).to eq(-1)
        expect(lfo.send(method).round(6)).to eq(-0.5)
        expect(lfo.send(method).round(6)).to eq(0)
      end

      it 'scales to a different range' do
        lfo = MB::Sound::Oscillator.new(:triangle, range: 2..5, advance: 0.25 * Math::PI)
        expect(lfo.send(method).round(6)).to eq(3.5)
        expect(lfo.send(method).round(6)).to eq(4.25)
        expect(lfo.send(method).round(6)).to eq(5)
        expect(lfo.send(method).round(6)).to eq(4.25)
        expect(lfo.send(method).round(6)).to eq(3.5)
        expect(lfo.send(method).round(6)).to eq(2.75)
        expect(lfo.send(method).round(6)).to eq(2)
        expect(lfo.send(method).round(6)).to eq(2.75)
        expect(lfo.send(method).round(6)).to eq(3.5)
      end

      it 'includes pre_power' do
        lfo = MB::Sound::Oscillator.new(:triangle, pre_power: 0.5, advance: 0.125 * Math::PI)

        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq((0.25 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq((0.75 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(1)
        expect(lfo.send(method).round(6)).to eq((0.75 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq((0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq((0.25 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(0)
        expect(lfo.send(method).round(6)).to eq(-(0.25 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-(0.75 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-1)
        expect(lfo.send(method).round(6)).to eq(-(0.75 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-(0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(-(0.25 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(0)
      end

      it 'clamps values with negative pre_power' do
        lfo = MB::Sound::Oscillator.new(:triangle, pre_power: -100)
        expect(lfo.send(method).round(6)).to eq(-1.0)
        expect(lfo.send(method).round(6)).to eq(1.0)
      end

      it 'applies pre_power before scaling' do
        lfo = MB::Sound::Oscillator.new(:triangle, range: 2..4, pre_power: 0.5, advance: 0.25 * Math::PI)
        expect(lfo.send(method).round(6)).to eq(3)
        expect(lfo.send(method).round(6)).to eq((3 + 0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(4)
        expect(lfo.send(method).round(6)).to eq((3 + 0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(3)
        expect(lfo.send(method).round(6)).to eq((3 - 0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(2)
        expect(lfo.send(method).round(6)).to eq((3 - 0.5 ** 0.5).round(6))
        expect(lfo.send(method).round(6)).to eq(3)
      end

      it 'applies post_power after scaling' do
        lfo = MB::Sound::Oscillator.new(:triangle, range: 2..4, post_power: 2, advance: 0.5 * Math::PI)
        expect(lfo.send(method).round(6)).to eq(9)
        expect(lfo.send(method).round(6)).to eq(16)
        expect(lfo.send(method).round(6)).to eq(9)
        expect(lfo.send(method).round(6)).to eq(4)
        expect(lfo.send(method).round(6)).to eq(9)
      end

      it 'takes phase into account' do
        lfo = MB::Sound::Oscillator.new(:square, phase: 0.9 * Math::PI, advance: 0.2 * Math::PI)
        expect(lfo.send(method)).to eq(1)
        expect(lfo.send(method)).to eq(-1)

        lfo = MB::Sound::Oscillator.new(:square, phase: 1.5 * Math::PI, advance: Math::PI)
        expect(lfo.send(method)).to eq(-1)
        expect(lfo.send(method)).to eq(1)
      end

      it 'can generate more than one sample' do
        oscil = MB::Sound::Oscillator.new(:sine, frequency: 100, advance: Math::PI / 24000)
        data = oscil.send(method, 48000)
        expect(data.length).to eq(48000)
        expect(data.min.round(3)).to eq(-1)
        expect(data.max.round(3)).to eq(1)
        expect(data.sum.round(2)).to eq(0)
      end

      it 'produces expected square wave output for a low sample rate' do
        oscil = 1.hz.square.at(0.5).at_rate(50).oscillator
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(-0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(0.5))
        expect(oscil.send(method, 25)).to eq(Numo::SFloat.zeros(25).fill(-0.5))
      end

      it 'produces expected square wave output for a moderate sample rate' do
        oscil = 1.hz.square.at_rate(1600).at(1).oscillator
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(-1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(1))
        expect(oscil.send(method, 800)).to eq(Numo::SFloat.zeros(800).fill(-1))
      end

      it 'matches the analytic signal for a complex sine wave' do
        oscil = 240.hz.complex_sine.at(1).oscillator
        result = oscil.send(method, 1600)
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.at(1).generate(1600)))

        expect(MB::M.round(result, 5)).to eq(MB::M.round(target, 5))
      end

      it 'matches the analytic signal for a complex square wave (approximately)' do
        oscil = 240.hz.complex_square.at(1).oscillator
        result = oscil.send(method, 1600)
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.square.at(1).generate(16000))[6401...8001])

        expect(MB::M.round(result.real, 5)).to eq(MB::M.round(target.real, 5))

        delta = result.imag - target.imag
        expect(delta.abs.max).to be < 0.4
        expect(delta.mean.abs).to be < 0.001
        expect(delta.abs.mean).to be < 0.05
      end

      it 'matches the analytic signal for a complex triangle wave (approximately)' do
        oscil = 240.hz.complex_triangle.at(1).oscillator
        result = oscil.send(method, 1600)
        target = Numo::SComplex.cast(MB::Sound.analytic_signal(240.hz.triangle.at(1).generate(16000))[6400...8000])

        expect(MB::M.round(result.real, 6)).to eq(MB::M.round(target.real, 6))

        delta = result.imag - target.imag
        expect(delta.abs.max).to be < 0.005
        expect(delta.mean.abs).to be < 0.0005
        expect(delta.abs.mean).to be < 0.0005
      end

      it 'matches the analytic signal for a complex ramp wave (approximately)' do
        oscil = 240.hz.complex_ramp.at(1).oscillator
        result = oscil.send(method, 1600)

        base = MB::Sound.analytic_signal(120.hz.ramp.at(1).generate(32000)).reshape(16000, 2)[nil, 1] # shift 240hz by half sample
        target = Numo::SComplex.cast(base)[6400...8000]

        expect(MB::M.round(result.real, 6)).to eq(MB::M.round(target.real, 6))

        delta = result.imag.clip(-1, 1) - target.imag.clip(-1, 1)
        expect(delta.abs.max).to be < 0.05
        expect(delta.mean.abs).to be < 0.0005
        expect(delta.abs.mean).to be < 0.01
      end

      it 'truncates output for short reads on frequency' do
        # FIXME/TODO: don't read one sample from frequency buffer in Oscillator#frequency=
        expect(0.constant.for(0.0001).tone.oscillator.send(method, 48000)).to eq(Numo::SFloat.zeros(4))
      end

      it 'truncates output for short reads on phase' do
        expect(0.hz.pm(0.constant.for(0.0001)).oscillator.send(method, 48000)).to eq(Numo::SFloat.zeros(5))
      end

      it 'raises an error if truncation happens twice' do
        a = 0.constant
        expect(a).to receive(:sample).with(10).twice.and_return(Numo::SFloat[1,2,3])

        osc = 0.hz.pm(a)
        expect(osc.sample(10).length).to eq(3)

        expect { osc.sample(10) }.to raise_error(/Truncation/)
      end
    end
  end

  describe '#trigger' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0, range: 0..0)
    }

    it 'changes frequency' do
      expect(oscil.frequency).to eq(0)

      oscil.trigger(25, 0)
      expect(oscil.frequency).to eq(MB::Sound::Note.new(25).frequency)
      expect(oscil.number).to eq(25)

      oscil.trigger(75, 0)
      expect(oscil.frequency).to eq(MB::Sound::Note.new(75).frequency)
      expect(oscil.number).to eq(75)
    end

    it 'changes amplitude' do
      expect(oscil.range).to eq(0..0)
      oscil.trigger(25, 127)
      expect(oscil.range.min.round(3)).to eq(-1 * -6.db.round(3))
      expect(oscil.range.max.round(3)).to eq(-6.db.round(3))
    end

    context 'with custom tuning' do
      after(:each) {
        MB::Sound::Oscillator.tune_note = nil
        MB::Sound::Oscillator.tune_freq = nil
        expect(MB::Sound::A3.frequency.round(5)).to eq(220)
      }

      it 'uses custom tuning references but only after triggering' do
        oscil.trigger(69, 127)
        expect(oscil.frequency.round(5)).to eq(440)

        MB::Sound::Oscillator.tune_freq = 460
        expect(oscil.frequency.round(5)).to eq(440)
        oscil.trigger(69, 127)
        expect(oscil.frequency.round(5)).to eq(460)

        MB::Sound::Oscillator.tune_note = 72
        MB::Sound::Oscillator.tune_freq = 512
        expect(oscil.frequency.round(5)).to eq(460)
        oscil.trigger(60, 127)
        expect(oscil.frequency.round(5)).to eq(256)
      end
    end
  end

  describe '#release' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0, range: 0.5..0.5)
    }

    it 'can handle out-of-range note numbers' do
      expect(oscil.number).not_to be_finite
      expect { oscil.release(oscil.number, 0) }.not_to raise_error
      expect(oscil.range).to eq(0..0)
    end

    it 'does not change frequency' do
      oscil.release(25, 0)
      expect(oscil.frequency).to eq(0)
    end

    it 'silences the oscillator for a matching event' do
      oscil.trigger(25, 0)
      oscil.release(25, 0)
      expect(oscil.range).to eq(0..0)
    end

    it 'does not silence the oscillator for a non-matching event' do
      oscil.trigger(25, 0)
      oscil.release(24, 0)
      expect(oscil.range.min.round(3)).to eq(-1 * -30.db.round(3))
      expect(oscil.range.max.round(3)).to eq(-30.db.round(3))
    end
  end

  describe '#phi=' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0)
    }

    it 'can change the oscillator phase' do
      # Check twice to make sure frequency is at 0
      expect(oscil.sample.round(5)).to eq(0)
      expect(oscil.sample.round(5)).to eq(0)

      oscil.phi += 90.degrees
      expect(oscil.sample.round(5)).to eq(1)

      oscil.phi += 90.degrees
      expect(oscil.sample.round(5)).to eq(0)

      oscil.phi += 90.degrees
      expect(oscil.sample.round(5)).to eq(-1)

      oscil.phi += 45.degrees
      expect(oscil.sample.round(5)).to eq(-(0.5 ** 0.5).round(5))

      oscil.phi += 45.degrees
      expect(oscil.sample.round(5)).to eq(0)
    end

    it 'clamps phase to 0..2pi' do
      oscil.phi = 362.degrees
      expect(oscil.phi.round(5)).to eq(2.degrees.round(5))
      oscil.phi = -2.degrees
      expect(oscil.phi.round(5)).to eq(358.degrees.round(5))
    end
  end

  describe '#phase=' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0)
    }

    it 'shifts the current phase by the difference in starting phases' do
      oscil.phi = 1
      oscil.phase = 1
      expect(oscil.phi).to eq(2)

      oscil.phase = 0
      oscil.phi = 0
      oscil.phase = -10
      expect(oscil.phi).to eq(-10 % (Math::PI * 2))
    end
  end

  describe '#reset' do
    let (:oscil) {
      MB::Sound::Oscillator.new(:sine, frequency: 0)
    }

    it 'sets the phase to its initial phase' do
      oscil.phi = 1
      oscil.reset
      expect(oscil.phi).to eq(0)
      oscil.phase = 2
      oscil.reset
      expect(oscil.phi).to eq(2)
    end
  end
end
