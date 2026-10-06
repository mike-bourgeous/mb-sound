# Phasors: tones that output their phase in cycles (Tone#phasor; formerly
# the Phasor class).
RSpec.describe('Tone#phasor', :aggregate_failures) do
  # A phasor at +frequency+ (Hz or a node) starting at +phase+ (cycles).
  def phasor(frequency, phase: 0.0, sample_rate: 48000)
    MB::Sound::Pitch.new(frequency, sample_rate: sample_rate).phasor(phase: phase)
  end

  describe '#sample' do
    it 'outputs the phase in cycles, starting at the starting phase' do
      p = phasor(4800, phase: 0.25)
      expect(p.sample(5).to_a).to eq([0.25, 0.35, 0.45, 0.55, 0.65].map { |v| v.to_f.round(7) }.map { |v| Numo::SFloat[v][0] })
    end

    it 'wraps the phase to 0...1' do
      p = phasor(12000)
      expect(p.sample(6).to_a).to eq([0, 0.25, 0.5, 0.75, 0, 0.25])
    end

    it 'keeps an exact phase for a constant frequency across buffers' do
      p = phasor(1, sample_rate: 1600)
      p.sample(800)
      expect(p.state.phi).to eq(0.5)
      p.sample(800)
      expect(p.state.phi).to eq(0)
    end

    it 'follows a frequency node' do
      p = phasor(MB::Sound::ArrayInput.new(data: [Numo::SFloat[4800, 9600, 2400, 0]]))
      expect(p.sample(4).to_a).to eq([0, 0.1, 0.3, 0.35].map { |v| Numo::SFloat[v][0] })
      expect(p.sample(4)).to eq(nil)
    end

    it 'returns single-precision buffers with a double-precision phase' do
      p = phasor(1.0 / 3)
      expect(p.sample(10)).to be_a(Numo::SFloat)
      expect(p.state.phi).to be_within(1e-15).of(10.0 / 3 / 48000)
    end

    it 'is a phasor' do
      expect(100.hz.phasor.phasor?).to eq(true)
      expect(100.hz.phasor.wave_type).to eq(:phasor)
      expect(100.hz.ramp.phasor?).to eq(false)
    end

    it 'has no amplitude' do
      expect { phasor(12000).at(0..2) }.to raise_error(ArgumentError, /amplitude/)
      expect { 100.hz.at(0.5).phasor }.to raise_error(ArgumentError, /amplitude/)
      expect((phasor(12000) * 2).sample(4).to_a).to eq([0, 0.5, 1, 1.5])
    end
  end

  describe 'resets' do
    it 'resets to the starting phase at each trigger' do
      trig = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(200).tap { |t| t[123] = 1 }])
      p = phasor(100, phase: 0.1).reset(trig)
      data = p.sample(200)
      expect(data[123]).to be_within(1e-7).of(0.1)
      expect(data[124]).to be_within(1e-7).of(0.1 + 100.0 / 48000)
    end

    it 'syncs to a number of cycles past the starting phase' do
      p = phasor(100, phase: 0.1)
      p.sync_cycles(2.3)
      expect(p.state.phi).to be_within(1e-12).of(0.4)
    end
  end

  describe '#sample_rate=' do
    it 'sets the advance to one cycle per Hz per sample rate' do
      p = phasor(1).at_rate(4)
      expect(p.advance).to eq(0.25)
      expect(p.sample(4).to_a).to eq([0, 0.25, 0.5, 0.75])
    end
  end

  describe 'C and Ruby versions' do
    let(:random) { Random.new(12345) }

    # Samples phasors made by the block with sample_c and sample_ruby.
    def both(buffers, count = 800)
      c = yield
      r = yield
      c_out = buffers.times.map { c.sample_c(count).dup }
      r_out = buffers.times.map { r.sample_ruby(count).dup }
      [c_out, r_out, c.state.phi, r.state.phi]
    end

    it 'match for constant frequencies' do
      [0, 1, 440, 7919.3, 23999, -250].each do |f|
        phase = random.rand
        c_out, r_out, c_phi, r_phi = both(3) { phasor(f, phase: phase) }
        c_out.zip(r_out).each { |c, r| expect(c).to all_be_within(1e-6).of_array(r) }
        expect(c_phi).to be_within(1e-12).of(r_phi)
      end
    end

    it 'match for varying frequencies' do
      data = Numo::SFloat.cast(Array.new(3200) { random.rand(-2000.0..20000.0) })
      c_out, r_out, c_phi, r_phi = both(4) { phasor(MB::Sound::ArrayInput.new(data: [data]), phase: 0.7) }
      c_out.zip(r_out).each { |c, r| expect(c).to all_be_within(1e-6).of_array(r) }
      expect(c_phi).to be_within(1e-9).of(r_phi)
    end
  end
end

RSpec.describe(MB::Sound::Tone, :aggregate_failures) do
  describe '.shape_ruby and MB::FastSound.shape' do
    let(:random) { Random.new(54321) }
    let(:phases) { Numo::DFloat.cast(Array.new(1000) { random.rand } + [0, 0.25, 0.5, 0.75]) }
    let(:increments) { Numo::DFloat.cast(Array.new(phases.length) { random.rand(0.0..0.01) }) }
    let(:phase_mod) { Numo::DFloat.cast(Array.new(phases.length) { random.rand(-3.0..3.0) }) }

    MB::Sound::Tone::WAVE_TYPES.each do |wave|
      it "match for #{wave}" do
        complex = MB::Sound::Tone::BUFFER_CLASS.include?(wave)
        buf = (complex ? Numo::SComplex : Numo::SFloat).zeros(phases.length)
        # C reads phases in single precision
        sphases = Numo::DFloat.cast(Numo::SFloat.cast(phases))

        c = MB::FastSound.shape(buf, wave, Numo::SFloat.cast(phases), Numo::SFloat.cast(increments), phase_mod, 1, 0)
        r = MB::Sound::Tone.shape_ruby(wave, sphases, Numo::DFloat.cast(Numo::SFloat.cast(increments)), Numo::DFloat.cast(Numo::SFloat.cast(phase_mod)))

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
        complex = MB::Sound::Tone::BUFFER_CLASS.include?(wave)
        freq = Numo::SFloat.linspace(100, 3000, 800)
        pm = Numo::SFloat.linspace(-1, 1, 800)

        phasor_state = [0.2]
        increments = Numo::SFloat.zeros(800)
        phases = MB::FastSound.phasor(Numo::SFloat.zeros(800), freq, 1.0 / 48000, 0, phasor_state, increments)
        shaped = MB::FastSound.shape((complex ? Numo::SComplex : Numo::SFloat).zeros(800), wave, phases, increments, pm, 0.5, 0.1)

        state = [0.2]
        fused = MB::FastSound.oscillate((complex ? Numo::SComplex : Numo::SFloat).zeros(800), wave, freq, pm, 1.0 / 48000, 0, 0.5, 0.1, state)

        expect(fused).to all_be_within(1e-5).of_array(shaped)
        expect(state[0]).to be_within(1e-12).of(phasor_state[0])
      end
    end
  end

  describe '#sample_c and #sample_ruby' do
    it 'match for FM and PM oscillators' do
      [:sine, :ramp, :complex_sine, :parabola].each do |wave|
        make = -> {
          MB::Sound::Tone.new(wave_type: wave, frequency: 220.hz.sine.at(100..600)).pm(3.hz.triangle.at(0..2))
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
