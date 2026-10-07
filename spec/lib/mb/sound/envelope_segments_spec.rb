RSpec.describe(MB::Sound::Envelope, 'multi-segment envelopes') do
  # Samples +count+ values in +buffer+-sized chunks with +method+, stopping
  # at nil.
  def collect(env, count, buffer: 800, method: :sample)
    out = []
    (count.to_f / buffer).ceil.times do
      buf = env.send(method, buffer)
      break if buf.nil?
      out << buf.dup
    end
    out.empty? ? Numo::SFloat[] : Numo::SFloat.zeros(0).concatenate(*out)[0...[count, out.sum(&:length)].min]
  end

  # A node of the values of +data+, then its last value forever.
  def array_node(data)
    MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(data)], repeat: false).then { |n|
      n.and_then(data[-1].to_f.constant)
    }
  end

  def gate_node(length, on)
    a = Numo::SFloat.zeros(length)
    a[on] = 1
    array_node(a)
  end

  describe 'kernels with loops' do
    it 'give exactly the same samples and state for random segment lists and loops' do
      rng = Random.new(4242)
      sf = MB::Sound::Envelope

      200.times do |trial|
        nseg = rng.rand(2..7)
        release_node = rng.rand(1..(nseg - 1))
        loop_node = rng.rand < 0.7 ? rng.rand(0..release_node) : -1
        flags = 0
        flags |= sf::FLAG_GATE if rng.rand < 0.6
        flags |= sf::FLAG_TRIGGER if rng.rand < 0.5
        flags |= sf::FLAG_ONE_SHOT if flags & 3 == 0
        flags |= sf::FLAG_ADD if rng.rand < 0.3
        flags |= sf::FLAG_ZERO if flags & sf::FLAG_ADD == 0 && rng.rand < 0.4
        config = [flags, release_node, rng.rand(0.0..0.5), 1.0, 0, 144.0, sf::CURVE_SCALE, 96.0, 0.01, loop_node]
        shapes = Array.new(nseg) { rng.rand < 0.3 ? 1 : 0 }

        state_c = Numo::DFloat.zeros(sf::STATE_SIZE)
        state_c[sf::STATE_STAGE] = flags & sf::FLAG_ONE_SHOT != 0 ? 5 : 0
        state_c[sf::STATE_PEAK] = 1
        state_r = state_c.dup

        times = Array.new(nseg) { rng.rand < 0.15 ? 0.0 : rng.rand(0.0..300.0) }
        curves = Array.new(nseg) { rng.rand(-60.0..60.0) }
        levels = Array.new(nseg) { |i| i == nseg - 1 ? 0.0 : rng.rand(-1.0..1.0) }
        hold = rng.rand < 0.3 ? Float::INFINITY : rng.rand(0.0..2000.0)

        4.times do
          n = rng.rand(1..900)
          gate = Numo::SFloat.cast(Array.new(n) { rng.rand < 0.995 ? 1 : 0 })
          trig = Numo::SFloat.cast(Array.new(n) { rng.rand < 0.003 ? 1 : 0 })
          inputs = [flags & 1 != 0 ? gate : nil, flags & 2 != 0 ? trig : nil, rng.rand, nil, nil, nil]

          out_c = MB::Sound::FastEnvelope.process(Numo::SFloat.zeros(n), state_c, times, curves, levels, hold, inputs, config, shapes)
          out_r = sf.process_ruby(Numo::SFloat.zeros(n), state_r, times, curves, levels, hold, inputs, config, shapes)

          expect(out_c.to_a).to eq(out_r.to_a), "trial #{trial}: outputs differ"
          expect(state_c.to_a).to eq(state_r.to_a), "trial #{trial}: states differ"
        end
      end
    end

    it 'accepts the old 9-value config and rejects bad loop nodes' do
      state = Numo::DFloat.zeros(MB::Sound::Envelope::STATE_SIZE)
      config = [1, 2, 1.0, 1.0, 0, 144, MB::Sound::Envelope::CURVE_SCALE, 96.0, 0.01]
      out = Numo::SFloat.zeros(10)
      args = [[1, 2, 3], [0, 0, 0], [1, 0.5, 0], 0, [nil] * 6]
      expect { MB::Sound::FastEnvelope.process(out, state, *args, config, [0, 0, 0]) }.not_to raise_error
      expect { MB::Sound::FastEnvelope.process(out, state, *args, config + [3], [0, 0, 0]) }.to raise_error(ArgumentError, /Loop node/)
      expect { MB::Sound::Envelope.process_ruby(out, state, *args, config + [3], [0, 0, 0]) }.to raise_error(ArgumentError, /Loop node/)
      expect { MB::Sound::FastEnvelope.process(out, state, *args, config + [-2], [0, 0, 0]) }.to raise_error(ArgumentError, /Loop node/)
    end

    it 'sustains instead of spinning on a loop of zero-length segments' do
      e = MB::Sound.env([[1, 0], [0.5, 0], [0, 0.1]], loop: 0, gate: 1)
      out = e.sample(100)
      expect(out[-1]).to eq(0.5)
      expect(e.stage).to eq(:sustain)
    end
  end

  describe 'ADSR equivalence' do
    [:adsr, :env, :amp_env, :fm_env, :filter_env].each do |preset|
      it "gives #{preset} exactly the same samples as its ADSR form" do
        sustain = [:fm_env, :filter_env].include?(preset) ? 0.0 : 0.6
        gate = gate_node(30000, 100..15000)
        gate2 = gate_node(30000, 100..15000)
        a = MB::Sound.public_send(preset, 0.01, 0.2, sustain, 0.3, gate: gate, velocity: 0.7)
        b = MB::Sound.public_send(preset, [[1, 0.01], [sustain, 0.2], [0, 0.3]], gate: gate2, velocity: 0.7)
        expect(b).to be_multi
        expect(b.curve.values).to eq(a.curve.values)
        expect(collect(b, 30000).to_a).to eq(collect(a, 30000).to_a)
      end
    end

    it 'gives Notes envelopes the same samples with GM scaling' do
      clip = MB::Sound.seq(60, 64).n4
      a = clip.notes.amp_env(0.01, 0.3, 0.5, 0.2)
      b = clip.notes.amp_env([[1, 0.01], [0.5, 0.3], [0, 0.2]])
      expect(b.base_times).to eq({ t1: 0.01, t2: 0.3, t3: 0.2 })
      expect(collect(b, 48000).to_a).to eq(collect(a, 48000).to_a)
      expect(collect(a, 48000).max).to be > 0.2
    end
  end

  describe 'segments' do
    it 'names segments t1..tN and finds the sustain level before the release' do
      e = MB::Sound.adsr([[1, 0.01], [0.3, 0.1], [0.8, 0.2], [0, 0.5]], release_at: 3)
      expect(e.names).to eq([:t1, :t2, :t3, :t4])
      expect(e.sustain).to eq(0.8)
      expect(e.release_node).to eq(3)
      expect(e.release).to eq(0.5)
      expect(e.time(:t2)).to eq(0.1)
      expect(e.level_of(1)).to eq(0.3)
      expect(e.segments[2]).to include(name: :t3, level: 0.8, time: 0.2)
    end

    it 'plays bipolar levels and lands on each one' do
      e = MB::Sound.adsr([[1, 0.01], [-0.5, 0.01], [0.25, 0.01], [0, 0.01]], release_at: 3, curve: :linear, hold: 0.05)
      out = collect(e, 4800)
      expect(out[480]).to eq(1)
      expect(out[960]).to eq(-0.5)
      expect(out[1440]).to eq(0.25)
      expect(out.min).to eq(-0.5)
      expect(out[-1]).to eq(0)
    end

    it 'applies curves by role, by name, and per segment' do
      e = MB::Sound.adsr([[1, 0.01], [0.3, 0.1], [0.8, 0.2, -6], [0, 0.5]], release_at: 3)
      expect(e.curve).to eq({ t1: 12.0, t2: 60.0, t3: -6.0, t4: 60.0 })
      e.curve(release: 30, t2: 0)
      expect(e.curve).to eq({ t1: 12.0, t2: 0.0, t3: -6.0, t4: 30.0 })
      e.curve(:linear)
      expect(e.curve.values.uniq).to eq([0.0])
      expect(MB::Sound.adsr([[1, 0.01, nil, :s], [0, 0.1]]).shape).to eq({ t1: :s, t2: :exp })
    end

    it 'takes Hash segments, names for release_at: and loop:, and node levels' do
      e = MB::Sound.adsr([{ level: 1, time: 0.01 }, { level: 0.5.constant, time: 0.05 }, { level: 0, time: 0.1 }], release_at: :t3, loop: :t2)
      expect(e.release_node).to eq(2)
      expect(e.loop_node).to eq(1)
      expect(e.sources).to include(:t2_level)
    end

    it 'rejects bad segment lists' do
      expect { MB::Sound.adsr([[1, 0.1]]) }.to raise_error(ArgumentError, /2 to/)
      expect { MB::Sound.adsr([[1, 0.1], [0, 0.1]], release_at: 2) }.to raise_error(ArgumentError, /release_at/)
      expect { MB::Sound.adsr([[1, 0.1], [0, 0.1]], loop: 3) }.to raise_error(ArgumentError, /loop/)
      expect { MB::Sound.adsr([[1, 0.1], [0, 0.1]], 0.2) }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound::Envelope.new(attack: 0.1, segments: [[1, 0.1], [0, 0.1]]) }.to raise_error(ArgumentError, /not both/)
      expect { MB::Sound::Envelope.new(loop: 1) }.to raise_error(ArgumentError, /segment list/)
    end

    it 'keeps ADSR to_s and describes segment lists' do
      expect(MB::Sound.adsr(0.01, 0.2, 0.7, 0.3).to_s).to include('adsr(0.01, 0.2, 0.7, 0.3) curve analog')
      s = MB::Sound.adsr([[1, 0.01], [0.5, 0.1], [0, 0.2]], loop: 1).to_s
      expect(s).to include('env(1.0/0.01, @0.5/0.1, | 0.0/0.2)')
    end
  end

  describe 'retrigger: :zero (restart from zero)' do
    # Gate on at 0 and again at 0.3 s (after a 1-sample gap), so the
    # second note starts while the first is sounding
    def regate
      a = Numo::SFloat.zeros(48000)
      a[0...14400] = 1
      a[14401...30000] = 1
      array_node(a)
    end

    it 'drops to 0 at a note start while sounding, then attacks again' do
      zero = MB::Sound.adsr(0.05, 0.1, 0.6, 0.2, gate: regate, retrigger: :zero, curve: :linear)
      plain = MB::Sound.adsr(0.05, 0.1, 0.6, 0.2, gate: regate, curve: :linear)
      z = collect(zero, 48000)
      p = collect(plain, 48000)
      expect(z[14400]).to be > 0.5           # sounding when the second note starts
      expect(z[14401]).to eq(0)
      expect(z[14401 + 1200]).to be_within(1e-6).of(0.5) # half way up the 50 ms attack
      expect(p[14401..(14401 + 1200)].min).to be > 0.5    # the default attacks from the current level
      expect(z[0...14401].to_a).to eq(p[0...14401].to_a)  # the same from silence
    end

    it 'gives the C kernel and the Ruby mirror the same samples, also with S shapes' do
      [:exp, :s].each do |shape|
        a = MB::Sound.adsr(0.05, 0.1, 0.6, 0.2, gate: regate, retrigger: :zero, shape: shape)
        b = MB::Sound.adsr(0.05, 0.1, 0.6, 0.2, gate: regate, retrigger: :zero, shape: shape)
        expect(collect(a, 48000).to_a).to eq(collect(b, 48000, method: :sample_ruby).to_a), shape.to_s
      end
    end

    it 'leaves the default unchanged (no flag) and is offered by sq80_env as restart: true' do
      expect(MB::Sound.adsr.kernel_config[0] & described_class::FLAG_ZERO).to eq(0)
      expect(MB::Sound.adsr(retrigger: :zero).kernel_config[0] & described_class::FLAG_ZERO).not_to eq(0)
      expect(MB::Sound.sq80_env(restart: true).retrigger).to eq(:zero)
      expect(MB::Sound.sq80_env.retrigger).to eq(:restart)
      expect { MB::Sound.adsr(retrigger: :nope) }.to raise_error(ArgumentError, /zero/)
    end
  end

  describe 'loops' do
    it 'repeats the loop segments while the gate is held, then releases' do
      gate = gate_node(48000, 0...24000)
      e = MB::Sound.adsr([[1, 0.01], [0.2, 0.05], [1, 0.05], [0, 0.1]], release_at: 3, loop: 1, gate: gate, curve: :linear)
      out = collect(e, 48000)
      held = out[480...24000]
      # Two 50 ms segments per cycle: 240 cycles of 100 ms in 0.49 s
      peaks = (1...held.length - 1).count { |i| held[i] == 1 && held[i - 1] < 1 }
      expect(peaks).to be_between(4, 5)
      expect(held.min).to be_within(1e-6).of(0.2)
      expect(out[24000 + 4800..].abs.max).to eq(0)
    end

    it 'runs straight into the release with loop at the release node (cycle)' do
      e = MB::Sound.adsr([[1, 0.01], [0.5, 0.01], [0, 0.01]], loop: 2, trigger: array_node([0, 1] + [0] * 10), hold: false, curve: :linear)
      out = collect(e, 2400)
      expect(out[1 + 480]).to eq(1)
      expect(out[1 + 960]).to eq(0.5)
      expect(out[1 + 1440]).to eq(0)
      expect(e.stage).to eq(:idle)
    end

    it 'loops forever as a one-shot without a hold' do
      e = MB::Sound.adsr([[1, 0.01], [0, 0.01], [0, 0.01]], loop: 0, hold: false, curve: :linear)
      out = collect(e, 48000)
      expect(out[-4800..].max).to eq(1)
      expect(e).not_to be_ended
    end
  end

  describe MB::Sound::SQ80 do
    it 'converts panel times from the manual chart' do
      expect(MB::Sound::SQ80.time(0)).to eq(0)
      expect(MB::Sound::SQ80.time(1)).to eq(0.01)
      expect(MB::Sound::SQ80.time(32)).to eq(0.57)
      expect(MB::Sound::SQ80.time(63)).to eq(20.48)
      expect(MB::Sound::SQ80.time(36)).to be_within(1e-12).of(Math.sqrt(0.57 * 1.44))
      expect { MB::Sound::SQ80.time(64) }.to raise_error(ArgumentError)
    end

    it 'keeps one frozen time buffer while the control holds still' do
      v = MB::Sound::Notes.new(MB::Sound.seq(72).n1.vel(0.5))
      ts = MB::Sound::SQ80::TimeScale.new(0.5, v.velocity, :velocity, 1.0)
      a = ts.sample(480)
      b = ts.sample(480)
      expect(a).to be_frozen
      expect(b).to equal(a)
      expect(a[0]).to eq(0.25)
      key = MB::Sound::SQ80::TimeScale.new(0.5, v.number, :key, 1.0)
      expect(key.sample(480)[0]).to eq(0.25) # an octave above C4 halves it
    end

    it 'converts bipolar levels' do
      expect(MB::Sound::SQ80.level(-63)).to eq(-1)
      expect(MB::Sound::SQ80.level(63)).to eq(1)
      expect(MB::Sound::SQ80.level(0)).to eq(0)
    end

    it 'builds the four segments, with a second release tail' do
      e = MB::Sound.sq80_env(l1: 63, l2: 30, l3: 40, t1: 1, t2: 24, t3: 30, t4: 32, second_release: true, hold: 1)
      expect(e.names.length).to eq(5)
      expect(e.release_node).to eq(3)
      expect(e.segments.map { |s| s[:level] }).to eq([1.0, 30 / 63.0, 40 / 63.0, 40 / 63.0 * MB::Sound::SQ80::SECOND_RELEASE_LEVEL, 0.0])
      out = collect(e, 48000 * 5)
      expect(out[48000 + (0.57 * 48000).round - 1]).to be_within(1e-5).of(40 / 63.0 * 0.125)
      expect(out[48000 * 3]).to be > 0
    end

    it 'scales levels with velocity' do
      lin = MB::Sound.sq80_env(lv: 63, velocity: 0.5, hold: 1, l3: 63)
      expect(lin.sensitivity).to eq(0.0..1.0)
      expect(collect(lin, 4800).max).to be_within(1e-6).of(0.5)
      exp = MB::Sound.sq80_env(lv: 63, lv_curve: :exp, velocity: 0.5, hold: 1, l3: 63)
      expect(collect(exp, 4800).max).to be_within(1e-4).of(10 ** (-20 / 20.0))
    end

    it 'shortens T1 with velocity and T2/T3 with the key in voices' do
      [[72, 1.0], [48, 0.2]].each do |note, vel|
        clip = MB::Sound.seq(note).n1.vel(vel)
        n = MB::Sound::Notes.new(clip.stream)
        e = n.sq80_env(l1: 63, l2: 0, l3: 0, t1: 32, t2: 32, t1v: 63, tk: 63, gm: false)
        out = collect(e, 48000 * 3)
        peak = out.to_a.index(out.max)
        t1 = (0.57 * (1 - 1.0 * vel) * 48000).round
        expect(peak).to be_within(2).of([t1 - 1, 0].max)
        # T2 halves per octave above C4 (doubles below)
        t2 = (0.57 * 2 ** (-(note - 60) / 12.0) * 48000).round
        land = (peak + 1...out.length).find { |i| out[i] == 0 }
        expect(land - peak).to be_within(3).of(t2)
      end
    end

    it 'runs every stage with cycle and ignores the key-up' do
      clip = MB::Sound.seq(60).n32
      n = MB::Sound::Notes.new(clip.stream)
      e = n.sq80_env(l1: 63, l2: 63, l3: 63, t1: 0, t2: 32, t3: 32, t4: 16, cycle: true, gm: false)
      expect(e.gate).to be_nil
      out = collect(e, 48000 * 2)
      # The note is 1/32 (62.5 ms at 120 BPM); the envelope holds L3 until T1+T2+T3 = 1.14 s
      expect(out[(1.1 * 48000).round]).to be_within(1e-6).of(1)
      # ...then releases over T4 (0.09 s) and ends with its stream
      expect(out.length).to be_within(800).of((1.23 * 48000).round)
      expect(out[-1]).to eq(0)
    end

    it 'loops as a rhythmic modulator while the key is held' do
      clip = MB::Sound.seq(60).n1
      n = MB::Sound::Notes.new(clip.stream)
      e = n.sq80_env(l1: 63, l2: -63, l3: 63, t1: 0, t2: 16, t3: 16, t4: 16, loop: :t2, gm: false)
      out = collect(e, 48000)
      crossings = (1...out.length).count { |i| out[i - 1] < 0 && out[i] >= 0 }
      expect(crossings).to be_between(4, 6) # 0.18 s per cycle
    end
  end
end
