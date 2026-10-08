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
end
