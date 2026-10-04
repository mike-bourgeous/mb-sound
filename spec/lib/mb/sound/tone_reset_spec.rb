RSpec.describe('Tone reset inputs, free and random phases') do
  let(:advance) { 2 * Math::PI / 48000 }

  def bl_osc(wave = :ramp, frequency: 1001.3, **opts)
    MB::Sound::Oscillator.new(wave, frequency: frequency, advance: advance, band_limit: true, **opts)
  end

  def triggers(count, *indices, value: 1)
    Numo::SFloat.zeros(count).tap { |t| indices.each { |i| t[i] = value } }
  end

  def input(data, repeat: false)
    MB::Sound::ArrayInput.new(data: [data], repeat: repeat)
  end

  # Samples +osc+ in pieces, calling the block between pieces (e.g. to jump
  # the phase), and returns all samples.
  def pieces(osc, method, lengths)
    out = []
    lengths.each_with_index do |n, i|
      yield osc, i if i > 0
      out << osc.public_send(method, n).dup
    end
    Numo::SFloat.zeros(0).concatenate(*out)
  end

  describe MB::Sound::Oscillator do
    [:sample_c, :sample_ruby].each do |method|
      context "with #{method}" do
        it 'jumps at the exact samples, like phi= between pieces' do
          o = bl_osc
          o.reset_input = input(triggers(100, 37, 80, value: 0.25))
          result = o.public_send(method, 100)

          expected = pieces(bl_osc, method, [37, 43, 20]) { |osc| osc.phi = 0 }
          expect(result).to eq(expected)
        end

        it 'puts a naive oscillator at the target phase on the reset sample' do
          o = MB::Sound::Oscillator.new(:ramp, frequency: 1001.3, advance: advance)
          o.reset_input = input(triggers(100, 37))
          o.reset_to = 0.5 * Math::PI
          result = o.public_send(method, 100)

          expect(result[36]).not_to be_within(0.1).of(0.5)
          expect(result[37]).to be_within(1e-6).of(0.5)
        end

        it 'handles resets on the first and last samples of a buffer' do
          o = bl_osc
          o.reset_input = input(triggers(128, 0, 63, 65))
          result = pieces(o, method, [64, 64]) {}

          expected = pieces(bl_osc, method, [63, 2, 63]) { |osc| osc.phi = 0 }
          expect(result).to eq(expected)
        end
      end
    end

    it 'gives the same samples in C and Ruby with resets, FM, PM, and a warp' do
      fm = Numo::SFloat.linspace(200, 3000, 256)
      pm = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(256).seq * 0.05) * 2)
      width = Numo::SFloat.linspace(0.2, 0.8, 256)
      trig = triggers(256, 5, 100, 101, 200)

      c, r = 2.times.map {
        bl_osc(:square, frequency: input(fm), phase_mod: input(pm), width: input(width)).tap { |o|
          o.reset_input = input(trig)
          o.reset_to = 1.0
        }
      }

      expect(c.sample_c(256)).to eq(r.sample_ruby(256))
    end

    it 'turns a reset into a band-limited step from the continuing value to the target phase' do
      continuing = bl_osc.sample(100).dup

      o = bl_osc
      o.reset_input = input(triggers(100, 37))
      result = o.sample(100).dup

      expect(result[0...37]).to eq(continuing[0...37])
      expect(result[37]).to be_within(0.01).of(continuing[37])

      # After the 32-sample step, the same as an oscillator started at phase 0
      fresh = bl_osc.sample(63).dup
      expect(result[(37 + 32)..]).to all_be_within(1e-6).of_array(fresh[32..])
    end

    it 'works with phase modulation' do
      pm = Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(200).seq * 0.07) * 1.5)
      continuing = bl_osc(:triangle, phase_mod: input(pm)).sample(200).dup

      o = bl_osc(:triangle, phase_mod: input(pm))
      o.reset_input = input(triggers(200, 60))
      result = o.sample(200).dup

      # The step starts from the phase-modulated value the wave would have had
      expect(result[60]).to be_within(0.01).of(continuing[60])

      fresh = bl_osc(:triangle, phase_mod: input(pm[60..].dup)).sample(140).dup
      expect(result[(60 + 32)..]).to all_be_within(1e-5).of_array(fresh[32..])
    end

    it 'works with frequency modulation' do
      fm = Numo::SFloat.linspace(300, 2000, 200)

      o = bl_osc(frequency: input(fm))
      o.reset_input = input(triggers(200, 90))
      result = o.sample(200).dup

      fresh = bl_osc(frequency: input(fm[90..].dup)).sample(110).dup
      expect(result[(90 + 32)..]).to all_be_within(1e-5).of_array(fresh[32..])
    end

    it 'reads a target node at the reset sample' do
      targets = Numo::SFloat.zeros(100)
      targets[0...50] = 0.5 * Math::PI
      targets[50..] = Math::PI

      o = MB::Sound::Oscillator.new(:ramp, frequency: 100, advance: advance)
      o.reset_input = input(triggers(100, 20, 70))
      o.reset_to = input(targets)
      result = o.sample(100)

      expect(result[20]).to be_within(1e-6).of(0.5)
      expect(result[70]).to be_within(1e-6).of(-1.0) # pi on a ramp is the jump to -1
    end

    it 'can be removed with nil' do
      o = bl_osc
      o.reset_input = input(triggers(100, 10))
      o.reset_input = nil
      expect(o.sample(100)).to eq(bl_osc.sample(100))
    end

    it 'keeps playing without resets after the reset input ends' do
      o = bl_osc
      o.reset_input = input(triggers(100, 10)) # ends after 100 samples
      ref = bl_osc
      ref.reset_input = input(triggers(300, 10))
      expect(pieces(o, :sample, [100, 100, 100]) {}).to eq(pieces(ref, :sample, [100, 100, 100]) {})
    end

    it 'gives the same samples as no reset input when the trigger is always zero' do
      o = bl_osc(:square)
      o.reset_input = input(triggers(256))
      expect(o.sample(256)).to eq(bl_osc(:square).sample(256))
    end

    it 'remembers a quiet frozen trigger buffer and still resets at a new one' do
      quiet = triggers(100).freeze
      bufs = [quiet, quiet, triggers(100, 40).freeze, quiet]
      o = bl_osc
      o.reset_input = MB::Sound::GraphNode::ProcNode.new(0.constant) { bufs.shift }
      ref = bl_osc
      ref.reset_input = input(triggers(400, 240))
      expect(pieces(o, :sample, [100] * 4) {}).to eq(ref.sample(400))
    end

    it 'cannot be combined with sync' do
      o = bl_osc
      o.reset_input = input(triggers(10, 1))
      expect { o.sync = input(triggers(10, 2)) }.to raise_error(ArgumentError, /reset/)

      s = bl_osc(sync: input(triggers(10, 2)))
      expect { s.reset_input = input(triggers(10, 1)) }.to raise_error(ArgumentError, /sync/)
    end

    it 'gives sync pulses (the wraps port) at reset samples' do
      o = MB::Sound::Oscillator.new(:ramp, frequency: 100, advance: advance)
      o.reset_input = input(triggers(100, 30))
      o.reset_to = Math::PI
      wraps = o.wraps
      o.sample(100)
      pulses = wraps.sample(100)

      expect(pulses[30]).to eq(1)
      expect(pulses.ne(0).where.to_a).to eq([30])
    end

    it 'lists the reset input and target node as sources' do
      trig = input(triggers(10, 1))
      to = input(Numo::SFloat.zeros(10))
      o = bl_osc
      o.reset_input = trig
      o.reset_to = to
      expect(o.sources.keys).to include(:reset, :reset_to)
    end
  end

  describe MB::Sound::Tone do
    describe '#reset' do
      it 'returns self and passes the input to the oscillator' do
        t = 100.hz.ramp
        expect(t.reset(input(triggers(10, 3)))).to equal(t)
        expect(t.oscillator.reset_input).not_to be_nil
        expect(t.reset_input).not_to be_nil
      end

      it 'works when set after the oscillator was made' do
        t = 100.hz.aramp
        t.sample(10)
        t.reset(input(triggers(10, 4)), to: 0.5 * Math::PI)
        expect(t.sample(10)[4]).to be_within(1e-6).of(0.5)
      end

      it 'takes a phase in radians, like #with_phase' do
        result = 100.hz.aramp.reset(input(triggers(100, 50)), to: 90.degrees).sample(100)
        expect(result[50]).to be_within(1e-6).of(100.hz.aramp.with_phase(90.degrees).sample(1)[0])
      end

      it 'goes to the starting phase from #with_phase by default' do
        result = 100.hz.aramp.with_phase(Math::PI / 4).reset(input(triggers(100, 50))).sample(100)
        expect(result[50]).to be_within(1e-6).of(0.25)
      end

      it 'can be removed with nil' do
        t = 100.hz.ramp.reset(input(triggers(100, 50))).reset(nil)
        expect(t.reset_input).to be_nil
        expect(t.sample(100)).to eq(100.hz.ramp.sample(100))
      end

      it 'reads a frozen shared trigger without changing it', :check_shared do
        trig = input(triggers(800, 100, 400), repeat: true)
        a = 100.hz.ramp.reset(trig)
        b = 200.hz.ramp.reset(trig)
        expect { 3.times { a.sample(800); b.sample(800) } }.not_to raise_error
      end

      it 'refuses sync' do
        expect { 100.hz.ramp.sync(ratio: 2).reset(input(triggers(10, 1))) }.to raise_error(ArgumentError, /sync/)
        expect { 100.hz.ramp.reset(input(triggers(10, 1))).sync(ratio: 2) }.to raise_error(ArgumentError, /reset/)
      end

      it 'makes a free tone not free, with a warning (the last call wins)' do
        t = nil
        expect { t = 100.hz.ramp.free.reset(input(triggers(10, 1))) }.to output(/reset overrides free/).to_stderr
        expect(t.free?).to eq(false)
        expect(t.reset_input).not_to be_nil
      end

      it 'is removed by #free, with a warning (the last call wins)' do
        t = 100.hz.aramp.reset(input(triggers(100, 50)), to: 1.0)
        t.oscillator
        expect { t.free }.to output(/free overrides reset/).to_stderr
        expect(t.free?).to eq(true)
        expect(t.reset_input).to be_nil
        expect(t.oscillator.reset_input).to be_nil
        expect(t.sample(100)).to eq(100.hz.aramp.sample(100))
      end

      it 'does not warn without a conflict' do
        expect { 100.hz.ramp.reset(input(triggers(10, 1))).rnd.free(false) }.not_to output.to_stderr
      end

      it 'rejects other targets' do
        expect { 100.hz.ramp.reset(input(triggers(10, 1)), to: 'x') }.to raise_error(ArgumentError)
      end

      it 'is available on Pitch' do
        expect(100.hz.reset(input(triggers(10, 1)))).to be_a(MB::Sound::Tone)
        expect(100.hz.free.free?).to eq(true)
        expect(100.hz.rnd.random_phase?).to eq(true)
      end

      context 'with to: :random' do
        def random_resets(seed)
          MB::Sound.seed(seed)
          t = 100.hz.aramp.reset(input(triggers(1000, 100, 400, 700)), to: :random)
          r = t.sample(1000)
          [r[100], r[400], r[700]]
        end

        it 'repeats with the same root seed' do
          expect(random_resets(3)).to eq(random_resets(3))
        end

        it 'differs between resets and root seeds' do
          values = random_resets(3)
          expect(values.uniq.length).to eq(3)
          expect(random_resets(4)).not_to eq(values)
        end

        it 'differs between tones' do
          MB::Sound.seed(3)
          trig = triggers(200, 100)
          a = 100.hz.aramp.reset(input(trig), to: :random).sample(200)[100]
          b = 100.hz.aramp.reset(input(trig), to: :random).sample(200)[100]
          expect(a).not_to eq(b)
        end

        it 'is the same as #rnd' do
          MB::Sound.seed(9)
          a = 100.hz.aramp.reset(input(triggers(300, 100, 200)), to: :random).sample(300)
          MB::Sound.seed(9)
          b = 100.hz.aramp.reset(input(triggers(300, 100, 200))).rnd.sample(300)
          expect(a).to eq(b)
        end

        it 'replaces #rnd with a fixed target, with a warning (the last call wins)' do
          t = nil
          expect { t = 100.hz.aramp.rnd.reset(input(triggers(100, 50)), to: 0.5 * Math::PI) }.to output(/overrides rnd/).to_stderr
          expect(t.random_phase?).to eq(false)
          expect(t.sample(100)[50]).to be_within(1e-6).of(0.5)
        end

        it 'is replaced by #rnd after a fixed target, with a warning (the last call wins)' do
          MB::Sound.seed(9)
          a = 100.hz.aramp.reset(input(triggers(300, 100, 200))).rnd.sample(300)

          MB::Sound.seed(9)
          t = nil
          expect { t = 100.hz.aramp.reset(input(triggers(300, 100, 200)), to: 1.0).rnd }.to output(/rnd overrides reset\(to:/).to_stderr
          expect(t.reset_to).to be_nil
          expect(t.sample(300)).to eq(a)
        end
      end
    end

    describe '#free' do
      it 'marks the tone as never reset' do
        t = 100.hz.ramp
        expect(t.free?).to eq(false)
        expect(t.free).to equal(t)
        expect(t.free?).to eq(true)
        expect(t.no_trigger?).to eq(true)
      end

      it 'is not implied by #lfo' do
        expect(1.hz.lfo.free?).to eq(false)
        expect(1.hz.lfo.reset(input(triggers(10, 1)))).to be_a(MB::Sound::Tone)
      end
    end

    describe '#random_phase' do
      it 'starts free-running tones at a random phase from the root seed' do
        MB::Sound.seed(11)
        a = 3.times.map { 100.hz.aramp.free.rnd.sample(1)[0] }
        MB::Sound.seed(11)
        b = 3.times.map { 100.hz.aramp.free.rnd.sample(1)[0] }

        expect(a).to eq(b)
        expect(a.uniq.length).to eq(3)
      end

      it 'takes an explicit seed' do
        a = 100.hz.aramp.rnd(seed: 5).sample(1)[0]
        b = 100.hz.aramp.random_phase(seed: 5).sample(1)[0]
        c = 100.hz.aramp.rnd(seed: 6).sample(1)[0]
        expect(a).to eq(b)
        expect(c).not_to eq(a)
      end

      it 'draws a seed from the root generator when called' do
        MB::Sound.seed(2)
        s = MB::Sound.next_seed
        MB::Sound.seed(2)
        expect(100.hz.rnd.seed).to eq(s)
      end

      it 'can be reseeded with #seed=, also after the oscillator was made' do
        a = 100.hz.aramp.rnd(seed: 5).sample(1)[0]
        t = 100.hz.aramp.rnd(seed: 1)
        t.oscillator
        t.seed = 5
        expect(t.sample(1)[0]).to eq(a)
      end

      it 'gives MIDI-style resets (Oscillator#reset) a new random phase' do
        t = 100.hz.aramp.rnd(seed: 1)
        values = 3.times.map { t.oscillator.reset; t.sample(1)[0] }
        expect(values.uniq.length).to eq(3)
      end

      it 'keeps a random offset for tempo-locked tones' do
        t = 100.hz.aramp.rnd(seed: 1)
        start = t.oscillator.phase
        t.sync_cycles(0)
        expect(t.oscillator.phi).to be_within(1e-9).of(start)
      end
    end
  end
end
