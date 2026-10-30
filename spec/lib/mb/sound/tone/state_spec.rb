RSpec.describe(MB::Sound::Tone::State) do
  it 'starts at the given phase, unprimed' do
    s = described_class.new(phase: 0.25)
    expect(s.phi).to eq(0.25)
    expect(s.phase).to eq([0.25])
    expect(s.blep[3]).to eq(0)
    expect(s.blit[6]).to eq(0)
    expect(s.jump_residual).to eq(nil)
    expect(s.random?).to eq(false)
  end

  it 'wraps phases set with #phi=' do
    s = described_class.new
    s.phi = 1.75
    expect(s.phi).to eq(0.75)
    s.phi = -0.25
    expect(s.phi).to eq(0.75)
  end

  it 'round-trips through plain values, including the random generator' do
    s = described_class.new(phase: 0.1)
    s.seed = 42
    3.times { s.random }
    s.blep.replace([0.5, 0.01, 0.0, 1])
    s.jump_residual = Numo::DFloat[0.1, -0.2]
    s.last_freq = 440.0
    s.last_width = 0.3

    h = s.to_h
    expect(h.values.flatten.map(&:class).uniq - [Float, Integer, NilClass, FalseClass, TrueClass]).to be_empty

    copy = described_class.new(**h)
    expect(copy.to_h).to eq(h)
    expect(copy.random).to eq(s.random)
  end

  it 'counts random draws and restarts the generator when reseeded' do
    s = described_class.new
    s.seed = 7
    a = s.random
    expect(s.draws).to eq(1)
    s.seed = 7
    expect(s.draws).to eq(0)
    expect(s.random).to eq(a)
  end

  it 'forgets band-limiting history on #unprime' do
    s = described_class.new(phase: 0.4)
    s.blep[3] = 1
    s.blit[6] = 1
    s.sync.replace([0.9, 0.1, -1.0, 3, 1])
    s.sync_ring.fill(1)
    s.unprime(sync: true)
    expect(s.blep[3]).to eq(2) # unprimed after a jump (a fresh 0 means a first sample)
    expect(s.blit[6]).to eq(0)
    expect(s.sync).to eq([0.4, 0.0, 1.0, 0, 0])
    expect(s.sync_ring.abs.max).to eq(0)
  end

  it 'rejects unknown fields' do
    expect { described_class.new(volume: 1) }.to raise_error(ArgumentError, /volume/)
  end

  describe 'jump steps (mb_jump_step.h and its Ruby reference)' do
    it 'queues and adds steps in C exactly as the Numo reference does, without allocating' do
      rng = Random.new(3)
      [Numo::SFloat, Numo::DFloat].each do |type|
        c = described_class.new
        r = described_class.new
        out_c = type.zeros(800)
        out_r = type.zeros(800)
        200.times do |i|
          case rng.rand(3)
          when 0
            dv = (rng.rand - 0.5) * 4
            ds = (rng.rand - 0.5) * 0.2
            k = [nil, 1.0, rng.rand].sample(random: rng)
            c.queue_jump(dv, ds, k)
            r.queue_jump_ruby(dv, ds, k)
          else
            len = [1, 7, 32, 40, rng.rand(1..60)].sample(random: rng)
            from = rng.rand(0..(800 - len))
            gain = rng.rand * 2 - 1
            c.add_jump(out_c[from...(from + len)], gain)
            r.add_jump_ruby(out_r[from...(from + len)], gain)
          end
          expect(c.jump_left).to eq(r.jump_left), "step #{i}"
          expect(c.to_h[:jump_residual]).to eq(r.to_h[:jump_residual]), "step #{i}"
        end
        expect(out_c.to_binary).to eq(out_r.to_binary), type.name # (bit for bit)
        expect(out_c.abs.max).to be > 0.1
      end

      # Steady state: queueing and adding allocate no objects
      st = described_class.new
      out = Numo::SFloat.zeros(128)
      st.queue_jump(0.5, 0.01, 0.9)
      st.add_jump(out, 1.0)
      # (GC.stat itself may allocate: compare with an empty loop)
      counts = [0, 100].map { |times|
        i = 0
        before = GC.stat(:total_allocated_objects)
        while i < times
          st.queue_jump(0.5, 0.01, 0.9)
          st.add_jump(out, 1.0)
          i += 1
        end
        GC.stat(:total_allocated_objects) - before
      }
      expect(counts[1]).to be <= counts[0]
    end

    it 'keeps complex steps and other buffer types on the Numo path' do
      st = described_class.new
      st.queue_jump(Complex(0.5, 0.25), 0.0)
      expect(st.jump_buffer).to be_a(Numo::DComplex)
      st.queue_jump(0.25, 0.0)
      ref = MB::Sound::Tone.jump_residual(Complex(0.5, 0.25), 0.0) + MB::Sound::Tone.jump_residual(0.25, 0.0)
      expect(st.jump_residual.to_a).to eq(ref.to_a)

      st.queue_jump(Complex(0.5, 0.25), 0.0, real: true)
      expect(st.jump_buffer).to be_a(Numo::DComplex) # (the pending complex samples stay complex)
      out = Numo::SComplex.zeros(40)
      st.add_jump(out, 1.0)
      expect(st.jump_pending?).to eq(false)
      expect(out[0].real).not_to eq(0)
    end
  end

  # kernels-1: a complex tone's pending jump residual came back from #to_h as
  # Complexes, and the constructor cast them to a DFloat (RangeError), so
  # Tone#plan_restore failed for complex tones mid-jump (check mode found it)
  it 'restores a complex jump residual and ring from #to_h' do
    s = described_class.new(phase: 0.1)
    s.jump_residual = Numo::DComplex[Complex(0.5, -0.25), Complex(0.1, 0)]
    s.sync_ring = Numo::DComplex.zeros(4) + Complex(0, 1)
    r = described_class.new(**s.to_h)
    expect(r.jump_residual).to be_a(Numo::DComplex)
    expect(r.jump_residual.to_a).to eq(s.jump_residual.to_a)
    expect(r.sync_ring.to_a).to eq(s.sync_ring.to_a)
  end
end
