# Direct tests of MB::Sound::FastLoop.run's argument checks (programs are
# tested through feedback loops in spec/lib/mb/sound/plan/loop_spec.rb).
RSpec.describe('MB::Sound::FastLoop') do
  let(:op) { MB::Sound::Plan::Loop::Program::OPCODES }

  # A program computing out = in * 0.5 + 1 (no state ops).
  def words(*body, nregs: 3, ninputs: 1, nrings: 0, ring_objects: [])
    Numo::Int32.cast([nregs, 2, ninputs, 0, nrings, 0, *(ninputs > 0 ? [0] : []), *ring_objects, *body])
  end

  let(:scalars) { Numo::DFloat[0.5, 1.0] }
  let(:body) { [op[:muls], 1, 0, 0, op[:adds], 2, 1, 1, op[:end]] }

  it 'runs a program per sample' do
    out = Numo::SFloat.zeros(4)
    MB::Sound::FastLoop.run(words(*body), scalars, [], [Numo::SFloat[1, 2, 3, 4]], [], [], out, 4)
    expect(out.to_a).to eq([1.5, 2.0, 2.5, 3.0])
  end

  it 'reads frozen inputs' do
    out = Numo::SFloat.zeros(2)
    MB::Sound::FastLoop.run(words(*body), scalars, [], [Numo::SFloat[2, 4].freeze], [], [], out, 2)
    expect(out.to_a).to eq([2.0, 3.0])
  end

  it 'rejects a bad header, opcodes, and registers' do
    out = Numo::SFloat.zeros(2)
    ins = [Numo::SFloat[1, 2]]
    expect { MB::Sound::FastLoop.run(Numo::Int32[1, 2], scalars, [], ins, [], [], out, 2) }.to raise_error(ArgumentError, /too short/)
    expect { MB::Sound::FastLoop.run(words(99), scalars, [], ins, [], [], out, 2) }.to raise_error(ArgumentError, /opcode/)
    expect { MB::Sound::FastLoop.run(words(op[:muls], 7, 0, 0, op[:end]), scalars, [], ins, [], [], out, 2) }.to raise_error(ArgumentError, /register/)
    expect { MB::Sound::FastLoop.run(words(op[:muls], 1, 0, 9, op[:end]), scalars, [], ins, [], [], out, 2) }.to raise_error(ArgumentError, /scalar/)
    expect { MB::Sound::FastLoop.run(words(op[:muls], 1, 0, 0), scalars, [], ins, [], [], out, 2) }.to raise_error(ArgumentError, /no end/)
  end

  it 'rejects mismatched inputs, short buffers, and frozen outputs' do
    out = Numo::SFloat.zeros(4)
    expect { MB::Sound::FastLoop.run(words(*body), scalars, [], [], [], [], out, 4) }.to raise_error(ArgumentError, /don't match/)
    expect { MB::Sound::FastLoop.run(words(*body), scalars, [], [Numo::SFloat[1, 2]], [], [], out, 4) }.to raise_error(ArgumentError, /at least 4/)
    expect { MB::Sound::FastLoop.run(words(*body), scalars, [], [Numo::DFloat[1, 2, 3, 4]], [], [], out, 4) }.to raise_error(ArgumentError, /SFloat/)
    expect { MB::Sound::FastLoop.run(words(*body), scalars, [], [Numo::SFloat[1, 2, 3, 4]], [], [], out.freeze, 4) }.to raise_error(RuntimeError, /frozen/)
  end

  it 'checks rings: writes, objects, buffers, and modes' do
    out = Numo::SFloat.zeros(4)
    ins = [Numo::SFloat[1, 2, 3, 4]]
    ring = [Numo::SFloat.zeros(64), 0, [], 1, nil, true]
    read_write = [op[:dread], 1, 0, op[:dwrite], 0, 0, op[:copy], 2, 1, op[:end]]
    w = words(*read_write, nrings: 1, ring_objects: [0])

    MB::Sound::FastLoop.run(w, scalars, [ring], ins, [], [3], out, 4)
    expect(out.to_a).to eq([0, 0, 0, 1])
    expect(ring[1]).to eq(4)
    expect(ring[2][0]).to eq(3.0)

    expect { MB::Sound::FastLoop.run(words(op[:dread], 1, 0, op[:end], nrings: 1, ring_objects: [0]), scalars, [ring], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /never written/)
    expect { MB::Sound::FastLoop.run(words(*read_write[0..5], op[:dwrite], 0, 0, op[:end], nrings: 1, ring_objects: [0]), scalars, [ring], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /twice/)
    expect { MB::Sound::FastLoop.run(w, scalars, [[1, 2]], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /ring 0 must be/)
    expect { MB::Sound::FastLoop.run(w, scalars, [[Numo::SFloat.zeros(64), 99, [], 1, nil, true]], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /write offset/)
    expect { MB::Sound::FastLoop.run(w, scalars, [[Numo::SFloat.zeros(64), 0, [], 7, nil, true]], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /interpolation/)
    expect { MB::Sound::FastLoop.run(w, scalars, [[Numo::SFloat.zeros(64), 0, [], 2, nil, true]], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /sinc kernel/)
    expect { MB::Sound::FastLoop.run(w, scalars, [[Numo::SFloat.zeros(2), 0, [], 1, nil, true]], ins, [], [3], out, 4) }.to raise_error(ArgumentError, /too small/)
    expect { MB::Sound::FastLoop.run(w, scalars, [ring], ins, [], [Numo::SFloat[1]], out, 4) }.to raise_error(ArgumentError, /delay 0/)
  end
end
