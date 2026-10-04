RSpec.describe(MB::Sound::Envelope) do
  # A graph node that plays the values of an NArray (then repeats the last
  # value, or ends if +:ends+ is true).  Buffers are frozen, like the shared
  # buffers of a Tee.
  let(:array_node_class) {
    Class.new do
      include MB::Sound::GraphNode
      include MB::Sound::GraphNode::SampleRateHelper

      def initialize(data, ends: false, sample_rate: 48000)
        @data = Numo::SFloat.cast(data)
        @ends = ends
        @pos = 0
        @sample_rate = sample_rate
      end

      def sources
        {}
      end

      def sample(count)
        if @pos >= @data.length
          return nil if @ends
          return Numo::SFloat.new(count).fill(@data[-1]).freeze
        end

        buf = @data[@pos...[@pos + count, @data.length].min]
        if buf.length < count && !@ends
          buf = buf.concatenate(Numo::SFloat.new(count - buf.length).fill(@data[-1]))
        end
        @pos += count
        buf.dup.freeze
      end
    end
  }

  # An array of +length+ values that are 0 except for +ones+ (sample
  # indices or ranges).
  def pulses(length, *ones)
    a = Numo::SFloat.zeros(length)
    ones.each { |i| a[i] = 1 }
    a
  end

  # Samples +count+ values in +buffer+-sized chunks, using +method+ (:sample
  # or :sample_ruby), stopping at nil.
  def collect(env, count, buffer: 800, method: :sample)
    out = []
    (count.to_f / buffer).ceil.times do
      buf = env.send(method, buffer)
      break if buf.nil?
      out << buf.dup
    end
    out.empty? ? Numo::SFloat[] : Numo::SFloat.zeros(0).concatenate(*out)[0...[count, out.sum(&:length)].min]
  end

  # The curve formula from the class description.
  def curve_p(d, x)
    c = d * MB::Sound::Envelope::CURVE_SCALE
    c == 0 ? x : (1 - Math.exp(c * x)) / (1 - Math.exp(c))
  end

  describe 'kernels' do
    it 'C and Ruby use the same state layout' do
      expect(MB::Sound::FastEnvelope::STATE_SIZE).to eq(MB::Sound::Envelope::STATE_SIZE)
    end

    # Random piecewise-constant signal of +n+ values in +range+ that changes
    # with probability +p+ per sample.
    def piecewise(rng, n, range, p, type: Numo::SFloat)
      v = rng.rand(range)
      type.cast(Array.new(n) { v = rng.rand(range) if rng.rand < p; v })
    end

    # Random 0/1 runs.
    def gates(rng, n, p)
      on = rng.rand < 0.5
      Numo::SFloat.cast(Array.new(n) { on = !on if rng.rand < p; on ? 1 : 0 })
    end

    # Random sparse pulses.
    def sparse(rng, n, p)
      Numo::SFloat.cast(Array.new(n) { rng.rand < p ? 1 : 0 })
    end

    it 'give exactly the same samples and state for random cases' do
      rng = Random.new(12345)

      300.times do |trial|
        nodes = rng.rand < 0.5
        flags = 0
        flags |= MB::Sound::Envelope::FLAG_GATE if rng.rand < 0.6
        flags |= MB::Sound::Envelope::FLAG_TRIGGER if rng.rand < 0.5
        flags |= MB::Sound::Envelope::FLAG_ONE_SHOT if flags & 3 == 0
        flags |= MB::Sound::Envelope::FLAG_LEGATO if rng.rand < 0.3
        flags |= MB::Sound::Envelope::FLAG_OCTAVES if rng.rand < 0.2
        flags |= MB::Sound::Envelope::FLAG_LIFT if rng.rand < 0.4
        db = rng.rand < 0.4
        config = [
          flags, 2,
          db ? rng.rand(0.05..0.5) : rng.rand(0.0..0.5), rng.rand(0.5..1.5),
          db ? 1 : 0,
          rng.rand(0.0..300.0),
          MB::Sound::Envelope::CURVE_SCALE,
        ]

        state_c = Numo::DFloat.zeros(MB::Sound::Envelope::STATE_SIZE)
        state_c[MB::Sound::Envelope::STATE_STAGE] = flags & MB::Sound::Envelope::FLAG_ONE_SHOT != 0 ? 5 : 0
        state_c[MB::Sound::Envelope::STATE_PEAK] = 1
        state_r = state_c.dup

        consts = {
          times: Array.new(3) { rng.rand < 0.1 ? 0.0 : rng.rand(0.0..400.0) },
          curves: Array.new(3) { rng.rand(-90.0..90.0) },
          levels: [1.0, rng.rand(0.0..1.2), 0.0],
          hold: rng.rand(0.0..300.0),
        }

        5.times do
          n = rng.rand(1..700)
          type = rng.rand < 0.5 ? Numo::SFloat : Numo::DFloat
          if nodes
            times = consts[:times].map { |t| rng.rand < 0.5 ? piecewise(rng, n, 0.0..400.0, 0.01, type: type) : t }
            curves = consts[:curves].map { |c| rng.rand < 0.5 ? piecewise(rng, n, -90.0..90.0, 0.01, type: type) : c }
            levels = [1.0, rng.rand < 0.5 ? piecewise(rng, n, 0.0..1.2, 0.01, type: type) : consts[:levels][1], 0.0]
            hold = rng.rand < 0.5 ? piecewise(rng, n, 0.0..300.0, 0.01) : consts[:hold]
          else
            times, curves, levels, hold = consts.values_at(:times, :curves, :levels, :hold)
          end

          inputs = [
            flags & 1 != 0 ? gates(rng, n, 0.01) : nil,
            flags & 2 != 0 ? (rng.rand < 0.5 ? sparse(rng, n, 0.005) : gates(rng, n, 0.01) * 2 - 0.5) : nil,
            rng.rand < 0.5 ? piecewise(rng, n, -0.1..1.1, 0.05) : (rng.rand < 0.5 ? rng.rand : nil),
            rng.rand < 0.5 ? sparse(rng, n, 0.002) : nil,
            rng.rand < 0.5 ? piecewise(rng, n, -0.1..1.1, 0.05) : (rng.rand < 0.5 ? rng.rand : nil),
            rng.rand < 0.5 ? piecewise(rng, n, -3.0..3.0, 0.01) : rng.rand(-3.0..3.0),
          ]

          out_c = MB::Sound::FastEnvelope.process(Numo::SFloat.zeros(n), state_c, times, curves, levels, hold, inputs, config)
          out_r = MB::Sound::Envelope.process_ruby(Numo::SFloat.zeros(n), state_r, times, curves, levels, hold, inputs, config)

          expect(out_c.to_a).to eq(out_r.to_a), "trial #{trial}: outputs differ"
          expect(state_c.to_a).to eq(state_r.to_a), "trial #{trial}: states differ"
        end
      end
    end

    it 'agree for whole envelopes with node parameters and inputs' do
      make = ->(m) {
        n = array_node_class
        described_class.new(
          attack: n.new([0.004] * 300 + [0.002] * 10000),
          decay: 1.n32,
          sustain: n.new([0.6] * 2000 + [0.3] * 10000),
          release: 96.samples,
          curve: { attack: n.new([12] * 100 + [-20] * 10000), decay: 60 },
          gate: n.new(pulses(6000, 50..2500, 3000..5000)),
          trigger: n.new(pulses(6000, 1000, 4000)),
          velocity: n.new(Numo::SFloat.linspace(0, 1, 6000)),
          choke: n.new(pulses(6000, 4500)),
          sensitivity: 0.25..1,
        )
      }

      a = collect(make.(nil), 6000, buffer: 333)
      b = collect(make.(nil), 6000, buffer: 333, method: :sample_ruby)
      expect(a.to_a).to eq(b.to_a)
      expect(a.max).to be > 0.5
    end

    it 'rejects mismatched buffer lengths and bad configs' do
      state = Numo::DFloat.zeros(MB::Sound::Envelope::STATE_SIZE)
      config = [1, 2, 1.0, 1.0, 0, 144, MB::Sound::Envelope::CURVE_SCALE]
      out = Numo::SFloat.zeros(10)
      expect {
        MB::Sound::FastEnvelope.process(out, state, [1, 2, 3], [0, 0, 0], [1, 0.5, 0], 0, [Numo::SFloat.zeros(9), nil, nil, nil, nil, nil], config)
      }.to raise_error(ArgumentError, /length/)
      expect {
        MB::Sound::FastEnvelope.process(out, state, [1, 2, 3], [0, 0, 0], [1, 0.5, 0], 0, [nil, nil, nil, nil, nil, nil], config.dup.tap { |c| c[1] = 3 })
      }.to raise_error(ArgumentError, /Release node/)
      expect {
        MB::Sound::FastEnvelope.process(out, Numo::DFloat.zeros(3), [1, 2, 3], [0, 0, 0], [1, 0.5, 0], 0, [nil, nil, nil, nil, nil, nil], config)
      }.to raise_error(ArgumentError, /State/)
      expect {
        MB::Sound::FastEnvelope.process(out, state, [1, 2, 3], [0, 0, 0], [1, 0.5, 0], 0, [nil, nil, nil, nil], config)
      }.to raise_error(ArgumentError, /lift/)
    end
  end

  describe 'one-shot' do
    it 'lands exactly on each target at its time, then ends' do
      env = described_class.new(attack: 0.01, decay: 0.02, sustain: 0.5, release: 0.005, hold: 0.1)
      expect(env.one_shot?).to eq(true)

      data = collect(env, 20000, buffer: 512)
      # attack 480, decay 960, release 4800 samples after the start, taking 240
      expect(data[0]).to eq(0)
      expect(data[479]).to be < 1
      expect(data[480]).to eq(1)
      expect(data[481]).to be < 1
      expect(data[1439]).to be > 0.5
      expect(data[1440..4800].to_a.uniq).to eq([0.5])
      expect(data[4801]).to be < 0.5
      expect(data[5039]).to be > 0
      expect(data[5040..].to_a.uniq).to eq([0])
      expect(data.length).to eq(5120) # 10 buffers, ending in the 10th
      expect(env.ended?).to eq(true)
      expect(env.stage).to eq(:ended)
      expect(env.sample(512)).to eq(nil)
    end

    it 'releases after twice the attack plus decay time by default, at least MIN_HOLD' do
      expect(described_class.new(attack: 0.1, decay: 0.2).hold).to eq(0.6000000000000001)
      expect(described_class.new(attack: 0.01, decay: 0.02).hold).to eq(0.1)
    end

    it 'releases from the current level when the hold ends during the attack or decay' do
      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, hold: 50.samples, curve: 0)
      data = env.sample(300)
      expect(data[49]).to be_within(1e-6).of(0.49)
      expect(data[50]).to be_within(1e-6).of(0.49)
      expect(data[100]).to be_within(1e-6).of(0.245)
      expect(data[150]).to eq(0)
      expect(env.ended?).to eq(true)

      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, hold: 150.samples, curve: 0)
      data = env.sample(300)
      expect(data[150]).to be_within(1e-6).of(0.755) # repeats sample 149
      expect(data[151]).to be < 0.755
      expect(data[250]).to eq(0)
    end

    it 'never ends with hold: false' do
      env = described_class.new(attack: 0.001, decay: 0.001, sustain: 0.25, release: 0.001, hold: false)
      100.times { expect(env.sample(4800)).not_to eq(nil) }
      expect(env.stage).to eq(:sustain)
      expect(env.level).to eq(0.25)
    end

    it 'returns nil for later calls after ending mid-buffer' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 0, hold: 10.samples)
      buf = env.sample(100)
      expect(buf[0...10].to_a.uniq).to eq([1])
      expect(buf[10..].to_a.uniq).to eq([0])
      expect(env.sample(100)).to eq(nil)
    end

    it 'can be reset' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 0, hold: 5.samples)
      expect(env.sample(10)[0]).to eq(1)
      expect(env.sample(10)).to eq(nil)
      env.reset
      expect(env.stage).to eq(:pending)
      expect(env.sample(10)[0]).to eq(1)
    end
  end

  describe 'curves' do
    [:linear, :analog, :snappy, :gentle, :swell, :dx].each do |preset|
      it "#{preset} matches the curve formula at half of each segment" do
        a, d, r = described_class::CURVES[preset]
        env = described_class.new(attack: 1000.samples, decay: 2000.samples, sustain: 0.25, release: 500.samples, hold: 4000.samples, curve: preset)
        data = collect(env, 5000)

        expect(data[500]).to be_within(1e-6).of(curve_p(a, 0.5))
        expect(data[1000]).to eq(1)
        expect(data[2000]).to be_within(1e-6).of(1 - 0.75 * curve_p(d, 0.5))
        expect(data[3000]).to eq(0.25)
        expect(data[4250]).to be_within(1e-6).of(0.25 - 0.25 * curve_p(r, 0.5))
        expect(data[4500]).to eq(0)
      end
    end

    it 'follows the formula on every sample' do
      env = described_class.new(attack: 100.samples, decay: 0, sustain: 1, release: 0, curve: 60)
      data = env.sample(101)
      expected = Numo::DFloat.linspace(0, 1, 101).map { |x| curve_p(60, x) }
      expect((data - expected).abs.max).to be < 1e-6
    end

    it 'moves fast first for positive curves and slowly first for negative ones' do
      fast = described_class.new(attack: 1000.samples, curve: 30).sample(1000)
      slow = described_class.new(attack: 1000.samples, curve: -30).sample(1000)
      expect(fast[250]).to be > 0.5
      expect(slow[750]).to be < 0.5
    end

    it 'accepts a number, Hash, Array, preset, or chained #curve' do
      env = described_class.new(curve: 30)
      expect(env.curve).to eq({ attack: 30, decay: 30, release: 30 })
      env = described_class.new(curve: { attack: 1, release: 2 })
      expect(env.curve).to eq({ attack: 1, decay: 60, release: 2 })
      env = described_class.new(curve: [1, 2, 3])
      expect(env.curve).to eq({ attack: 1, decay: 2, release: 3 })
      env = described_class.new(curve: :dx)
      expect(env.curve).to eq({ attack: -30, decay: 30, release: 30 })
      expect(env.curve(:gentle)).to equal(env)
      expect(env.curve).to eq({ attack: 6, decay: 21, release: 21 })
      expect(env.curve(release: 5).curve).to eq({ attack: 6, decay: 21, release: 5 })
      expect(env.curve(7, 8, 9).curve).to eq({ attack: 7, decay: 8, release: 9 })
      expect { env.curve(:bogus) }.to raise_error(ArgumentError, /bogus/)
      expect { env.curve(sustain: 3) }.to raise_error(ArgumentError, /sustain/)
      expect { env.curve([1, 2]) }.to raise_error(ArgumentError, /3 values/)
    end
  end

  describe 're-planning' do
    it 'keeps the level continuous when an attack time node jumps, then lands at the new time' do
      env = described_class.new(attack: array_node_class.new([0.01] * 200 + [0.02] * 5000), decay: 0, sustain: 1, release: 0, curve: 0)
      data = collect(env, 2000)
      diffs = data.diff
      expect(diffs.abs.max).to be < 1.0 / 400
      expect(data[200]).to be_within(1e-6).of(data[199] + (1 - data[199]) / 761)
      expect(data[959]).to be < 1
      expect(data[960]).to eq(1)
    end

    it 'keeps the level continuous when a curve node jumps' do
      env = described_class.new(attack: 1000.samples, decay: 0, sustain: 1, release: 0, curve: array_node_class.new([60] * 300 + [-60] * 2000))
      data = collect(env, 1500)
      expect(data.diff.abs.max).to be < 0.01
      expect(data[1000]).to eq(1)
      # The rest of the segment follows a slow-first curve from sample 299
      expect(data[650]).to be < (data[299] + 1) / 2
    end

    it 'lands on a new sustain level when the sustain node changes during the decay' do
      env = described_class.new(attack: 0, decay: 1000.samples, sustain: array_node_class.new([0.5] * 500 + [0.2] * 5000), release: 0, curve: 60)
      data = collect(env, 1500)
      expect(data.diff.abs.max).to be < 0.05
      expect(data[1000]).to eq(Numo::SFloat[0.2][0])
      expect(data[1200]).to eq(Numo::SFloat[0.2][0])
    end

    it 'jumps to the target when a time shrinks below the elapsed time' do
      env = described_class.new(attack: array_node_class.new([0.01] * 300 + [0.001] * 5000), decay: 0, sustain: 1, release: 0)
      data = env.sample(400)
      expect(data[299]).to be < 1
      expect(data[300]).to eq(1)
    end
  end

  describe 'inputs' do
    it 'skips the kernel while idle with quiet frozen inputs, with the same samples and state as the Ruby kernel' do
      quiet = Numo::SFloat.zeros(100).freeze
      on = Numo::SFloat.zeros(100).tap { |b| b[30..] = 1 }.freeze
      off = Numo::SFloat.ones(100).tap { |b| b[50..] = 0 }.freeze
      trig = Numo::SFloat.zeros(100).tap { |b| b[10] = 0.7 }.freeze
      gates = [quiet, quiet, on, off, quiet, quiet, quiet, quiet, quiet, quiet]
      trigs = [quiet, quiet, quiet, quiet, quiet, trig, quiet, quiet, quiet, quiet]

      envs = [:sample, :sample_ruby].map { |method|
        g = gates.dup
        tr = trigs.dup
        env = described_class.new(
          attack: 0.0005, decay: 0.0005, sustain: 0.5, release: 0.0005, hold: 0.001,
          gate: MB::Sound::GraphNode::ProcNode.new(0.constant) { g.shift },
          trigger: MB::Sound::GraphNode::ProcNode.new(0.constant) { tr.shift }
        )
        data = gates.length.times.map { env.public_send(method, 100).dup }.reduce(:concatenate)
        [data, env.instance_variable_get(:@state).to_a]
      }

      expect(envs[0][0].to_a).to eq(envs[1][0].to_a)
      expect(envs[0][1]).to eq(envs[1][1])
      expect(envs[0][0].max).to be > 0.5
    end

    it 'gives the same samples for frozen input buffers seen again as for fresh copies' do
      on = Numo::SFloat.ones(100).freeze
      off = Numo::SFloat.zeros(100).freeze
      vel = Numo::SFloat.new(100).fill(0.6).freeze
      gates = [off, on, on, on, off, off, on, off, off]
      outputs = [true, false].map { |reuse|
        g = gates.dup
        v = [vel] * gates.length + [nil] * 3
        gate = MB::Sound::GraphNode::ProcNode.new(0.constant) { b = g.shift || off; reuse ? b : b.dup }
        velocity = MB::Sound::GraphNode::ProcNode.new(0.constant) { b = v.shift; reuse || b.nil? ? b : b.dup }
        env = described_class.new(attack: 0.002, decay: 0.002, sustain: 0.5, release: 0.002, gate: gate, velocity: velocity, sensitivity: 0..1)
        12.times.map { env.sample(100).dup }.reduce(:concatenate)
      }
      expect(outputs[0].to_a).to eq(outputs[1].to_a)
      expect(outputs[0].max).to be > 0.5
    end

    it 'starts the attack on a rising gate mid-buffer and releases on a falling gate' do
      gate = array_node_class.new(pulses(2000, 123..999))
      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 200.samples, gate: gate)
      expect(env.idle?).to eq(true)
      data = env.sample(2000)
      expect(data[0..123].to_a.uniq).to eq([0])
      expect(data[124]).to be > 0
      expect(data[223]).to eq(1)
      expect(data[323..999].to_a.uniq).to eq([0.5])
      expect(data[1000]).to eq(0.5)
      expect(data[1001]).to be < 0.5
      expect(data[1199]).to be > 0
      expect(data[1200..].to_a.uniq).to eq([0])
      expect(env.idle?).to eq(true)
      expect(env.sample(100)).not_to eq(nil)
    end

    it 'releases from the current level when the gate falls during the attack' do
      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, gate: array_node_class.new(pulses(400, 0...50)), curve: 0)
      data = env.sample(400)
      expect(data[49]).to be_within(1e-6).of(0.49)
      expect(data[50]).to be_within(1e-6).of(0.49)
      expect(data[100]).to be_within(1e-6).of(0.245)
      expect(data[150]).to eq(0)
    end

    it 'restarts the attack from the current level on each trigger' do
      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, hold: 300.samples, trigger: array_node_class.new(pulses(1000, 10, 150)), curve: 0)
      data = env.sample(1000)
      expect(data[0..10].to_a.uniq).to eq([0])
      expect(data[110]).to eq(1)
      expect(data[150]).to eq(data[149])
      expect(data[151]).to be > data[150]
      expect(data[250]).to eq(1)
      expect(data[350..450].to_a.uniq).to eq([0.5])
      expect(data[550..].to_a.uniq).to eq([0])
      expect(env.idle?).to eq(true)
    end

    it 'triggers only on rising edges, across buffers, ignoring negative values' do
      trigger = Numo::SFloat.zeros(3000)
      trigger[10...700] = 1     # held: one note
      trigger[700...800] = -1   # negative: ignored
      trigger[799] = 0
      trigger[800...1000] = 0.5 # rising from -1/0 to 0.5: one note at 800
      trigger[1200] = -1
      trigger[1500...2500] = 1  # one note, crossing a buffer boundary
      env = described_class.new(attack: 0, decay: 50.samples, sustain: 0, release: 0, hold: false, trigger: array_node_class.new(trigger), curve: 0)
      data = collect(env, 3000, buffer: 1600)
      expect(data[10]).to eq(1)
      expect(data[60..799].to_a.uniq).to eq([0])
      expect(data[800]).to eq(1)
      expect(data[850..1499].to_a.uniq).to eq([0])
      expect(data[1500]).to eq(1)
      expect(data[1550..].to_a.uniq).to eq([0])
    end

    it 'scales the release time by lift read on the release sample' do
      gate = pulses(3000, 0...100, 1000...1100, 2000...2100)
      lift = Numo::SFloat.zeros(3000).fill(0.5)
      lift[1100] = 0
      lift[2100] = 1
      lift[2101..] = 0
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 100.samples, gate: array_node_class.new(gate), lift: array_node_class.new(lift), curve: 0)
      data = env.sample(3000)
      expect(data[199]).to be > 0
      expect(data[200]).to eq(0)
      expect(data[1299]).to be > 0
      expect(data[1300]).to eq(0)
      expect(data[2149]).to be > 0
      expect(data[2150]).to eq(0)

      plain = described_class.new(attack: 0, decay: 0, sustain: 1, release: 100.samples, gate: array_node_class.new(gate), curve: 0)
      plain_data = plain.sample(3000)
      expect(plain_data[1199]).to be > 0
      expect(plain_data[1200]).to eq(0)
      expect(described_class.lift_scale(0.5)).to eq(1)
      expect(described_class.lift_scale(0)).to eq(2)
      expect(described_class.lift_scale(1)).to eq(0.5)
    end

    it 'scales the peak by velocity read on the note start sample' do
      vel = Numo::SFloat.zeros(1000)
      vel[0...100] = 0.9
      vel[100] = 0.5
      vel[101..] = 0.1
      env = described_class.new(attack: 50.samples, decay: 50.samples, sustain: 0.5, release: 0, sensitivity: 0.5..1,
                                gate: array_node_class.new(pulses(1000, 100..900)), velocity: array_node_class.new(vel))
      data = env.sample(1000)
      expect(data[150]).to eq(0.75)
      expect(data[300]).to eq(0.375)
    end

    it 'scales velocity in dB' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 0, sensitivity: -20.db..0.db, velocity_scale: :db,
                                trigger: array_node_class.new(pulses(10, 0)), velocity: 0.5, hold: false)
      expect(env.sample(10)[5]).to be_within(1e-6).of(-10.db)
    end

    it 'ignores velocity with sensitivity 0 or nil' do
      [0, nil].each do |s|
        env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 0, sensitivity: s, trigger: 1, velocity: 0.1)
        expect(env.sample(10)[5]).to eq(1)
        expect(env.sensitivity).to eq(nil)
      end
    end

    it 'chokes to zero in CHOKE_TIME' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 1, gate: 1, choke: array_node_class.new(pulses(1000, 200)))
      data = env.sample(1000)
      expect(data[0..200].to_a.uniq).to eq([1])
      expect(data[201]).to be < 1
      expect(data[343]).to be > 0
      expect(data[344..].to_a.uniq).to eq([0])
      expect(env.stage).to eq(:idle)
    end

    it 'ends a choked one-shot' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 1, choke: array_node_class.new(pulses(1000, 10)))
      expect(env.sample(1000)[154..].to_a.uniq).to eq([0])
      expect(env.sample(1000)).to eq(nil)
    end

    it 'restarts on triggers while the gate is held unless legato' do
      gate = pulses(1000, 10..900)
      trigger = pulses(1000, 500)
      normal = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, gate: array_node_class.new(gate), trigger: array_node_class.new(trigger))
      legato = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 100.samples, gate: array_node_class.new(gate), trigger: array_node_class.new(trigger)).legato
      expect(legato.legato?).to eq(true)

      a = normal.sample(1000)
      b = legato.sample(1000)
      expect(a[600]).to eq(1)
      expect(b[400..900].to_a.uniq).to eq([0.5])
      expect(a[0...500].to_a).to eq(b[0...500].to_a)
    end

    it 'releases a triggered note that reaches sustain while the gate is low' do
      env = described_class.new(attack: 10.samples, decay: 10.samples, sustain: 0.5, release: 10.samples, gate: 0, trigger: array_node_class.new(pulses(100, 5)), curve: 0)
      data = env.sample(100)
      expect(data[15]).to eq(1)
      expect(data[25]).to eq(0.5)
      expect(data[35]).to eq(0)
    end

    it 'treats ended input nodes as low gates' do
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 10.samples, gate: array_node_class.new([1] * 100, ends: true))
      expect(env.sample(80).to_a.uniq).to eq([1])
      data = env.sample(80)
      expect(data[19]).to eq(1)
      expect(data[30..].to_a.uniq).to eq([0])
    end

    it 'never modifies frozen input buffers', :check_shared do
      tee_source = array_node_class.new(pulses(2000, 100..1500))
      gate = tee_source.tee(2)
      env = described_class.new(gate: gate[0], velocity: 0.5)
      other = gate[1]
      2.times do
        expect { env.sample(1000) }.not_to raise_error
        expect(other.sample(1000)).to be_frozen
      end
    end

    it 'rejects a Range given as velocity' do
      expect { described_class.new(velocity: 0.5..1) }.to raise_error(ArgumentError, /sensitivity/)
    end
  end

  describe 'lengths' do
    it 'accepts seconds, milliseconds, samples, and Durations' do
      env = described_class.new(attack: 10.ms, decay: 96.samples, sustain: 0.5, release: 1.n16, hold: 577.samples)
      expect(env.attack_time).to be_within(1e-12).of(0.01)
      expect(env.decay_time).to be_within(1e-12).of(0.002)
      expect(env.release_time).to be_within(1e-12).of(MB::Sound::Sequence.transport.seconds(1/16r))
      data = collect(env, 48000)
      release = (MB::Sound::Sequence.transport.seconds(1/16r) * 48000).round
      expect(data[480]).to eq(1)
      expect(data[576]).to eq(0.5)
      expect(data[577]).to eq(0.5)
      expect(data[577 + release - 1]).to be > 0
      expect(data[577 + release]).to eq(0)
    end

    it 'follows tempo changes with Durations' do
      transport = MB::Sound::Sequence.transport
      old_bpm = transport.bpm
      begin
        env = described_class.new(attack: 1.n16, decay: 0, sustain: 1, release: 0, gate: array_node_class.new(pulses(100000, 0...10000, 20000...35000)))
        transport.bpm = 120
        data = env.sample(20000)
        expect(data[6000]).to eq(1) # 1/16 at 120 BPM = 0.125 s
        expect(data[5999]).to be < 1
        transport.bpm = 60
        data = env.sample(20000)
        expect(data[11999]).to be < 1
        expect(data[12000]).to eq(1)
      ensure
        transport.bpm = old_bpm
      end
    end
  end

  describe '#sample_rate=' do
    it 'keeps times in seconds' do
      env = described_class.new(attack: 0.01, decay: 0, sustain: 1, release: 0).at_rate(96000)
      expect(env.sample_rate).to eq(96000)
      data = env.sample(1000)
      expect(data[959]).to be < 1
      expect(data[960]).to eq(1)
    end

    it 'rescales a running segment' do
      env = described_class.new(attack: 0.01, decay: 0, sustain: 1, release: 0, curve: 0)
      a = env.sample(240)
      env.sample_rate = 96000
      b = env.sample(1000)
      expect(b[0]).to be_within(0.01).of(a[-1])
      expect(b[479]).to be < 1
      expect(b[480]).to eq(1)
    end

    it 'keeps Samples lengths in samples' do
      env = described_class.new(attack: 100.samples, decay: 0, sustain: 1, release: 0).at_rate(96000)
      expect(env.sample(200)[100]).to eq(1)
    end
  end

  describe 'octaves' do
    it 'outputs 2 ** (level * octaves)' do
      env = described_class.new(attack: 100.samples, decay: 100.samples, sustain: 0.5, release: 0, octaves: 3, hold: false)
      data = env.sample(300)
      expect(data[0]).to eq(1)
      expect(data[100]).to eq(8)
      expect(data[250]).to be_within(1e-5).of(2 ** 1.5)
    end

    it 'reads a graph node every sample' do
      depth = Numo::SFloat.zeros(300).fill(1)
      depth[150..] = 3
      env = described_class.new(attack: 0, decay: 0, sustain: 1, release: 0, hold: false, octaves: array_node_class.new(depth))
      data = env.sample(300)
      expect(data[149]).to eq(2)
      expect(data[150]).to eq(8)
      expect(env.sources).to include(:octaves)
    end

    it 'accepts anything with #to_octaves' do
      interval = Struct.new(:o) { def to_octaves = o }.new(1.5)
      expect(described_class.new(octaves: interval).octaves).to eq(1.5)
    end
  end

  describe '#sources' do
    it 'lists node parameters and inputs' do
      g = 1.constant
      env = described_class.new(attack: 2.constant, release: 1.n8, sustain: 0.5.constant, curve: { decay: 3.constant }, gate: g)
      expect(env.sources.keys).to contain_exactly(:attack, :release, :sustain, :decay_curve, :gate)
      expect(env.graph).to include(g)
    end
  end

  describe '#to_s' do
    it 'describes the envelope' do
      expect(described_class.new(attack: 0.01, curve: :snappy).to_s).to include('adsr(0.01, 0.2, 0.7, 0.3) curve snappy')
    end
  end
end
