# Direct tests of MB::Sound::FastPlan (the plan executor): its tables match
# the Ruby side's, programs built with Plan::Builder give the same samples
# in C as their Ruby mirror, and bad arguments raise instead of reading
# out of bounds.
RSpec.describe(MB::Sound::FastPlan) do
  let(:prog_class) { MB::Sound::Plan::Program }

  it 'has the Ruby side\'s register kinds, opcodes, kernels, and waves' do
    e = MB::Sound::FastPlan.enums
    prog_class::REG_KINDS.each { |k, v| expect(e[:"reg_#{k}"]).to eq(v), k.to_s }
    prog_class::OPCODES.each { |k, v| expect(e[k]).to eq(v), k.to_s }
    MB::Sound::Plan::Op::Tone::KERNELS.each { |k, v| expect(e[:"tone_#{k}"]).to eq(v), k.to_s }
    MB::Sound::Plan::Op::Tone::WAVES.each { |k, v| expect(e[:"osc_#{k}"]).to eq(v), k.to_s }
    MB::Sound::Plan::Op::Tone::BL_WAVES.each { |k, v| expect(e[:"bl_#{k}"]).to eq(v), k.to_s }
    el = MB::Sound::Plan::EventList
    expect([e[:events_held], e[:events_impulses]]).to eq([el::MODE_HELD, el::MODE_IMPULSES])
    expect([e[:ev_fill], e[:ev_impulse], e[:ev_glide], e[:ev_buffer], e[:ev_ramp]]).to eq([el::FILL, el::IMPULSE, el::GLIDE, el::BUFFER, el::RAMP])
    expect(e[:env_state_size]).to eq(MB::Sound::FastEnvelope::STATE_SIZE)
  end

  # A standalone program over +inputs+ (types from the buffers), built by
  # the block from the input Values.
  def program(inputs, params = [])
    b = MB::Sound::Plan::Builder.new
    ins = inputs.map { |buf| b.input(buf.is_a?(Numo::SComplex) ? :complex : :real, source: nil, handles: [], reason: 'test') }
    ps = params.map { |c| b.param(c) }
    out = yield(b, *ins, *ps)
    out = b.copy(out) if out.op.is_a?(MB::Sound::Plan::Op::Input) || out.op.is_a?(MB::Sound::Plan::Op::Param)
    prog_class.new(ops: b.ops, inputs: b.inputs, params: b.params, output: out)
  end

  def real(n, seed)
    Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(n).seq * (0.37 * seed) + seed) * 1.7)
  end

  def cplx(n, seed)
    Numo::SComplex.cast(real(n, seed) + real(n, seed + 10) * 1i)
  end

  [1, 2, 3, 127, 800].each do |n|
    it "gives the same samples as the Ruby mirror for every arithmetic op (#{n} samples)" do
      x, y = real(n, 1), real(n, 2)
      z, w = cplx(n, 3), cplx(n, 4)
      d = Numo::SFloat.cast(real(n, 5).abs + 0.5)
      prog = program([x, y, z, w, d]) { |b, a, bb, c, cc, dd|
        t1 = b.const(0.3) * a * bb               # muls, mul
        t2 = t1 + b.const(-1.25)                 # adds
        t3 = c * t2 * cc + a                     # complex mul (both kinds), complex + real
        t4 = (b.const(Complex(0.5, -2)) * t3) + b.const(Complex(1, 1))
        t5 = t4.real + t4.imag * 0.5 + (a / dd) + (a / 3) + (dd ** bb)
        t6 = b.fill(b.const(Complex(0.25, 0.75))) * t5
        t6.real * 2
      }
      out = Numo::SFloat.zeros(n)
      prog.run(n, [x, y, z, w, d], [], out)
      expect(out.to_binary).to eq(prog.run_ruby(n, [x, y, z, w, d], []).to_binary)
    end
  end

  it 'reads params as values (filled) or buffers (in place)' do
    c1 = 0.5.constant
    c2 = Complex(1, 2).constant
    x = real(64, 1)
    prog = program([x], [c1, c2]) { |b, a, p1, p2| (a * p1 + p2).imag + p1 }
    [[0.5, Complex(1, 2)], [real(64, 7), cplx(64, 8)], [3, Complex(0, -1)]].each do |params|
      out = Numo::SFloat.zeros(64)
      prog.run(64, [x], params, out)
      expect(out.to_binary).to eq(prog.run_ruby(64, [x], params).to_binary)
    end
  end

  it 'reuses scratch slots without clobbering live values' do
    x = real(100, 1)
    prog = program([x]) { |b, a| (1..12).reduce(a * 0.5) { |s, k| s + a * k } }
    out = Numo::SFloat.zeros(100)
    prog.run(100, [x], [], out)
    expect(out.to_binary).to eq(prog.run_ruby(100, [x], []).to_binary)
    expect(prog.lower[3]).to be <= 3 # 24 values
  end

  it 'copies an output that is an input' do
    x = real(10, 1)
    prog = program([x]) { |b, a| a }
    out = Numo::SFloat.zeros(10)
    prog.run(10, [x], [], out)
    expect(out.to_a).to eq(x.to_a)
  end

  describe 'argument checks' do
    let(:x) { real(16, 1) }
    let(:prog) { program([x]) { |b, a| a * 2 * a } }

    it 'raises for an input of the wrong type or length' do
      expect { prog.run(16, [real(8, 1)], [], Numo::SFloat.zeros(16)) }.to raise_error(ArgumentError, /input 0/)
      expect { prog.run(16, [cplx(16, 1)], [], Numo::SFloat.zeros(16)) }.to raise_error(ArgumentError, /input 0/)
      expect { prog.run(16, [Numo::DFloat.cast(x)], [], Numo::SFloat.zeros(16)) }.to raise_error(ArgumentError, /input 0/)
    end

    it 'raises for an output of the wrong type or length' do
      expect { prog.run(16, [x], [], Numo::SFloat.zeros(8)) }.to raise_error(ArgumentError, /output/)
      expect { prog.run(16, [x], [], Numo::SComplex.zeros(16)) }.to raise_error(ArgumentError, /output/)
    end

    it 'raises for a missing input read by an arithmetic op' do
      expect { prog.run(16, [nil], [], Numo::SFloat.zeros(16)) }.to raise_error(ArgumentError, /operand/)
    end

    it 'raises for bad words, scalars, and scratch' do
      words, scalars, objects, = prog.lower
      out = Numo::SFloat.zeros(16)
      scratch = Numo::SFloat.zeros(64)
      run = ->(w, s = scalars, sc = scratch) { MB::Sound::FastPlan.run(w, s, objects, [x], [], sc, out, 16) }

      expect { run.(Numo::Int32[1]) }.to raise_error(ArgumentError, /short/)
      expect { run.(Numo::Int32.cast(words.to_a.tap { |a| a[0] = 99 })) }.to raise_error(ArgumentError, /register table/)
      expect { run.(Numo::Int32.cast(words.to_a + [77, 0, 0, 0])) }.to raise_error(ArgumentError, /opcode/)
      expect { run.(Numo::Int32.cast(words.to_a + [2, 0, 5, 0])) }.to raise_error(ArgumentError, /operand/)
      expect { run.(Numo::Int32.cast(words.to_a[0...-1])) }.to raise_error(ArgumentError, /Truncated/)
      expect { run.(words, Numo::DFloat[]) }.to raise_error(ArgumentError, /scalar/)
      expect { run.(words, scalars, Numo::SFloat.zeros(4)) }.to raise_error(ArgumentError, /scratch/)
      expect { run.(Numo::DFloat.cast(words)) }.to raise_error(ArgumentError, /Int32/)
    end
  end

  describe 'tone op' do
    around do |ex|
      old = MB::Sound::Plan.precision
      MB::Sound::Plan.precision = :exact
      ex.run
    ensure
      MB::Sound::Plan.precision = old
    end

    it 'runs a naive and a band-limited tone like the Tone does, including resets' do
      [[:sine, 0], [:complex_sine, 0], [:ramp, 1]].each do |wave, _|
        mk = -> { MB::Sound::Tone.new(wave_type: wave, frequency: 500) }
        t1 = mk.call
        t2 = mk.call
        trig = Numo::SFloat.zeros(300).tap { |a| a[[0, 10, 11, 200]] = 1 }
        b = MB::Sound::Plan::Builder.new
        tr = b.input(:real, source: nil, handles: [], reason: 'test')
        b.node_stack.push(t2)
        v = b.tone(t2, frequency: 500, phase_mod: 0, reset: tr)
        b.node_stack.pop
        prog = prog_class.new(ops: b.ops, inputs: b.inputs, params: b.params, output: v)
        t2.plan_start
        out = (v.complex? ? Numo::SComplex : Numo::SFloat).zeros(300)
        prog.run(300, [trig], [], out)

        t1.reset(MB::Sound::ArrayInput.new(data: [trig]))
        expect(out.to_binary).to eq(t1.sample(300).to_binary), wave.to_s
      end
    end
  end

  describe 'event, keep, and envelope ops' do
    # A stand-in for an event-driven node: its lists are filled by hand.
    let(:feeder) {
      Class.new {
        def plan_event_list(port = nil) = (@lists ||= {})[port] ||= MB::Sound::Plan::EventList.new
        def plan_feed(count); end
        def plan_finished? = false
      }.new
    }

    def events_program(feeder)
      program([]) { |b| b.events(feeder) * 1 }
    end

    [1, 2, 7, 128, 800].each do |n|
      it "renders held lists, impulses, glides, and buffers as the Ruby mirror does (#{n} samples)" do
        list = feeder.plan_event_list
        buf = Numo::SFloat.cast(real(800, 3))
        prog = events_program(feeder)
        cases = [
          -> { list.held!.fill(0, n, 0.25) },
          -> { list.held!.fill(0, [n / 3, 1].max, 1.0 / 3).glide([n / 3, 1].max, n, 40.0, 52.5, 3, 97, 0.4).fill(n, n + 5, 9) },
          -> { list.held!.glide(0, n, 60.0, 48.0, 0, 50, 0).buffer(n / 2, n, buf) },
          -> { list.impulses!.impulse(0, 0.5).impulse(n - 1, 1.0 / 7).impulse(n + 3, 2) },
          -> { list.held!.ramp(0, [n / 2, 1].max, 3, 7).ramp([n / 2, 1].max, n, 100, 1001) },
        ]
        cases.each do |make|
          make.call
          c = prog.run(n, [], [], Numo::SFloat.zeros(n))
          r = prog.run_ruby(n, [], [])
          expect(c.to_a).to eq(r.to_a)
        end
      end
    end

    it 'gives Notes::Glide#fill\'s ramp' do
      expect(MB::Sound::Plan::EventList.glide_ruby(5, 40.0, 52.0, 3, 9, 0.2)[-1]).to be_within(1e-12).of(
        MB::Sound::Plan::EventList.glide_ruby(1, 40.0, 52.0, 7, 9, 0.2)[0]
      )
      expect(MB::Sound::Plan::EventList.glide_last(5, 40.0, 52.0, 3, 9, 0.2)).to eq(Numo::SFloat.cast(MB::Sound::Plan::EventList.glide_ruby(5, 40.0, 52.0, 3, 9, 0.2))[-1])
    end

    it 'smooths and takes maximums as the Ruby mirror does, with jumps' do
      [1, 5, 128, 600].each do |n|
        x = Numo::SFloat.cast((real(n, 4) * 3).round / 3)
        y = real(n, 6)
        sm1 = MB::Sound::Notes::Smoother.new(0.002, sample_rate: 48000)
        sm2 = MB::Sound::Notes::Smoother.new(0.002, sample_rate: 48000)
        [sm1, sm2].each { |sm| sm.plan_start(0.25) }
        jumps = [n / 3, n / 2].uniq
        prog = ->(sm) { program([x, y]) { |b, xi, yi| b.max(b.smooth(xi, sm, jumps), yi) } }
        c = prog.(sm1).run(n, [x, y], [], Numo::SFloat.zeros(n))
        r = prog.(sm2).run_ruby(n, [x, y], [])
        expect(c.to_a).to eq(r.to_a)
        expect(sm1.plan_snapshot).to eq(sm2.plan_snapshot)
      end
    end

    it 'keeps the last sample in an instance variable or a Hash' do
      x = real(9, 2)
      target = Object.new
      h = {}
      prog = program([x]) { |b, a| b.keep_last(a, target, :@kept); b.keep_last(a, h, :k); a * 2 }
      prog.run(9, [x], [], Numo::SFloat.zeros(9))
      expect(target.instance_variable_get(:@kept)).to eq(x[-1])
      expect(h[:k]).to eq(x[-1])
    end

    it 'runs an envelope as FastEnvelope.process does, with inputs from registers' do
      gate = Numo::SFloat.zeros(900).tap { |g| g[10...400] = 1 }
      vel = Numo::SFloat.new(900).fill(0.7)
      e1 = MB::Sound.adsr(0.002, 0.003, 0.4, 0.004, gate: 0, velocity: 0, curve: [3, 30, 20])
      e2 = MB::Sound.adsr(0.002, 0.003, 0.4, 0.004, gate: 0, velocity: 0, curve: [3, 30, 20])
      [1, 7, 128, 300, 464].each do |n|
        off = [1, 7, 128, 300, 464].take_while { |k| k != n }.sum
        g, v = gate[off...(off + n)].dup, vel[off...(off + n)].dup
        prog = program([g, v]) { |b, gi, vi|
          b.envelope(e1, times: [96.0, 144.0, 192.0], curves: [3.0, 30.0, 20.0], levels: [1.0, 0.4, 0.0], hold: Float::INFINITY,
                     gate: gi, trigger: nil, velocity: vi, choke: nil, lift: nil, octaves: nil)
        }
        c = prog.run(n, [g, v], [], Numo::SFloat.zeros(n))
        args = e2.send(:kernel_args)
        out = Numo::SFloat.zeros(n)
        MB::Sound::FastEnvelope.process(out, e2.plan_state, args[0], args[1], args[2], args[5], [g, nil, v, nil, nil, nil], args[4], args[6])
        expect(c.to_a).to eq(out.to_a)
        expect(e1.plan_state.to_a).to eq(e2.plan_state.to_a)
      end
    end

    it 'raises for bad event lists and envelope words instead of reading out of bounds' do
      list = feeder.plan_event_list
      prog = events_program(feeder)
      out = Numo::SFloat.zeros(8)
      list.held!.fill(0, 8, 1)
      list.data[0] = 5
      expect { prog.run(8, [], [], out) }.to raise_error(ArgumentError, /mode/)
      list.held!.fill(0, 8, 1)
      list.data[1] = 9
      expect { prog.run(8, [], [], out) }.to raise_error(ArgumentError, /kind/)
      list.held!.buffer(0, 8, Numo::DFloat.zeros(8))
      expect { prog.run(8, [], [], out) }.to raise_error(ArgumentError, /buffer/)
      list.held!.fill(4, 2, 1)
      expect { prog.run(8, [], [], out) }.to raise_error(ArgumentError, /entry/)
      list.held!.data.push(1)
      expect { prog.run(8, [], [], out) }.to raise_error(ArgumentError, /length/)

      e = MB::Sound.adsr(0.002, 0.003, 0.4, 0.004, gate: 0)
      eprog = program([]) { |b| b.envelope(e, times: [1.0, 2.0, 3.0], curves: [0.0, 0.0, 0.0], levels: [1.0, 0.5, 0.0], hold: 1.0, gate: nil, trigger: nil, velocity: nil, choke: nil, lift: nil, octaves: nil) * 1 }
      words, scalars, objects, = eprog.lower
      run = ->(w, sc = scalars) { MB::Sound::FastPlan.run(w, sc, objects, [], [], Numo::SFloat.zeros(64), out, 8) }
      expect { run.(words) }.not_to raise_error
      at = words.to_a.index(prog_class::OPCODES[:envelope])
      expect { run.(Numo::Int32.cast(words.to_a.tap { |a| a[at + 4] = 40 })) }.to raise_error(ArgumentError, /envelope/)
      expect { run.(Numo::Int32.cast(words.to_a.tap { |a| a[at + 3] = 9999 })) }.to raise_error(ArgumentError, /scalars/)
      expect { run.(Numo::Int32.cast(words.to_a.tap { |a| a[at + 8] = 7 })) }.to raise_error(ArgumentError, /shape/)
      expect { run.(Numo::Int32.cast(words.to_a.tap { |a| a[at + 5] = 99 })) }.to raise_error(ArgumentError, /register/)
    end
  end
end
