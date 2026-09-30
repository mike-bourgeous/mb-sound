RSpec.describe(MB::Sound::Phasor, :aggregate_failures) do
  describe '#sample' do
    it 'outputs the phase in cycles, starting at the starting phase' do
      p = MB::Sound::Phasor.new(frequency: 4800, phase: 0.25)
      expect(p.sample(5).to_a).to eq([0.25, 0.35, 0.45, 0.55, 0.65].map { |v| v.to_f.round(7) }.map { |v| Numo::SFloat[v][0] })
    end

    it 'wraps the phase to 0...1' do
      p = MB::Sound::Phasor.new(frequency: 12000)
      expect(p.sample(6).to_a).to eq([0, 0.25, 0.5, 0.75, 0, 0.25])
    end

    it 'keeps an exact phase for a constant frequency across buffers' do
      p = MB::Sound::Phasor.new(frequency: 1, sample_rate: 1600)
      p.sample(800)
      expect(p.phi).to eq(0.5)
      p.sample(800)
      expect(p.phi).to eq(0)
    end

    it 'follows a frequency node' do
      p = MB::Sound::Phasor.new(frequency: MB::Sound::ArrayInput.new(data: [Numo::SFloat[4800, 9600, 2400, 0]]))
      expect(p.sample(4).to_a).to eq([0, 0.1, 0.3, 0.35].map { |v| Numo::SFloat[v][0] })
      expect(p.sample(4)).to eq(nil)
    end

    it 'returns single-precision buffers with a double-precision phase' do
      p = MB::Sound::Phasor.new(frequency: 1.0 / 3)
      expect(p.sample(10)).to be_a(Numo::SFloat)
      expect(p.phi).to be_within(1e-15).of(10.0 / 3 / 48000)
    end
  end

  describe '#reset, #sync, and #phase=' do
    let(:p) { MB::Sound::Phasor.new(frequency: 100, phase: 0.1) }

    it 'resets to the starting phase' do
      p.sample(123)
      p.reset
      expect(p.phi).to be_within(1e-15).of(0.1)
    end

    it 'syncs to a number of cycles past the starting phase' do
      p.sync(2.3)
      expect(p.phi).to be_within(1e-12).of(0.4)
    end

    it 'shifts the current phase when the starting phase changes' do
      p.sample(48) # 0.1 cycles
      p.phase = 0.3
      expect(p.phi).to be_within(1e-12).of(0.4)
      expect(p.phase).to be_within(1e-15).of(0.3)
    end
  end

  describe '#sample_rate=' do
    it 'sets the advance to one cycle per Hz per sample rate' do
      p = MB::Sound::Phasor.new(frequency: 1).at_rate(4)
      expect(p.advance).to eq(0.25)
      expect(p.sample(4).to_a).to eq([0, 0.25, 0.5, 0.75])
    end
  end

  describe 'C and Ruby versions' do
    let(:random) { Random.new(12345) }

    def both(phasor_args, freq_values)
      c = MB::Sound::Phasor.new(**phasor_args)
      r = MB::Sound::Phasor.new(**phasor_args)
      c_out = []
      r_out = []
      freq_values.each do |f|
        count = f.is_a?(Numo::NArray) ? f.length : 800
        c_out << c.phases_c(f, count).dup
        r_out << r.phases_ruby(f, count)[0]
      end
      [c_out, r_out, c.phi, r.phi]
    end

    it 'match for constant frequencies' do
      [0, 1, 440, 7919.3, 23999, -250].each do |f|
        c_out, r_out, c_phi, r_phi = both({ phase: random.rand }, [f, f, f])
        c_out.zip(r_out).each { |c, r| expect(c).to all_be_within(1e-6).of_array(r) }
        expect(c_phi).to be_within(1e-12).of(r_phi)
      end
    end

    it 'match for varying frequencies' do
      buffers = 4.times.map { Numo::SFloat.cast(Array.new(800) { random.rand(-2000.0..20000.0) }) }
      c_out, r_out, c_phi, r_phi = both({ phase: 0.7 }, buffers)
      c_out.zip(r_out).each { |c, r| expect(c).to all_be_within(1e-6).of_array(r) }
      expect(c_phi).to be_within(1e-9).of(r_phi)
    end
  end
end

RSpec.describe(MB::Sound::Oscillator, :aggregate_failures) do
  describe '.shape_ruby and MB::FastSound.shape' do
    let(:random) { Random.new(54321) }
    let(:phases) { Numo::DFloat.cast(Array.new(1000) { random.rand } + [0, 0.25, 0.5, 0.75]) }
    let(:increments) { Numo::DFloat.cast(Array.new(phases.length) { random.rand(0.0..0.01) }) }
    let(:phase_mod) { Numo::DFloat.cast(Array.new(phases.length) { random.rand(-3.0..3.0) }) }

    MB::Sound::Oscillator::WAVE_TYPES.each do |wave|
      it "match for #{wave}" do
        complex = MB::Sound::Oscillator::BUFFER_CLASS.include?(wave)
        buf = (complex ? Numo::SComplex : Numo::SFloat).zeros(phases.length)
        # C reads phases in single precision
        sphases = Numo::DFloat.cast(Numo::SFloat.cast(phases))

        c = MB::FastSound.shape(buf, wave, Numo::SFloat.cast(phases), Numo::SFloat.cast(increments), phase_mod, 1, 0)
        r = MB::Sound::Oscillator.shape_ruby(wave, sphases, Numo::DFloat.cast(Numo::SFloat.cast(increments)), Numo::DFloat.cast(Numo::SFloat.cast(phase_mod)))

        # Discontinuities can land on either side from rounding, so compare
        # all but a few samples exactly and allow outliers at jumps
        diff = complex ? (Numo::DComplex.cast(c) - r).abs : (Numo::DFloat.cast(c) - r).abs
        expect((diff.lt(1e-4)).count_true).to be >= phases.length - 3
      end
    end
  end

  describe 'fused C loop (MB::FastSound.oscillate)' do
    it 'matches a phasor followed by a shaper' do
      [:sine, :triangle, :complex_square, :gauss].each do |wave|
        complex = MB::Sound::Oscillator::BUFFER_CLASS.include?(wave)
        freq = Numo::SFloat.linspace(100, 3000, 800)
        pm = Numo::SFloat.linspace(-1, 1, 800)

        phasor = MB::Sound::Phasor.new(phase: 0.2)
        increments = Numo::SFloat.zeros(800)
        phases = MB::FastSound.phasor(Numo::SFloat.zeros(800), freq, phasor.advance, 0, phasor.state, increments)
        shaped = MB::FastSound.shape((complex ? Numo::SComplex : Numo::SFloat).zeros(800), wave, phases, increments, pm, 0.5, 0.1)

        state = [0.2]
        fused = MB::FastSound.oscillate((complex ? Numo::SComplex : Numo::SFloat).zeros(800), wave, freq, pm, 1.0 / 48000, 0, 0.5, 0.1, state)

        expect(fused).to all_be_within(1e-5).of_array(shaped)
        expect(state[0]).to be_within(1e-12).of(phasor.phi)
      end
    end
  end

  describe '#sample_c and #sample_ruby' do
    it 'match for FM and PM oscillators' do
      [:sine, :ramp, :complex_sine, :parabola].each do |wave|
        make = -> {
          MB::Sound::Oscillator.new(
            wave,
            frequency: 220.hz.sine.at(100..600).forever,
            phase_mod: 3.hz.triangle.at(0..2).forever,
            advance: 2 * Math::PI / 48000
          )
        }
        c = make.call
        r = make.call
        3.times do
          expect(c.sample_c(800).dup).to all_be_within(1e-4).of_array(r.sample_ruby(800).dup)
        end
      end
    end
  end
end
