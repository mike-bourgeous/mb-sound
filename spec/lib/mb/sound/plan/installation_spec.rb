# The region finder, hooks, rebuilds, fallbacks, introspection, and check
# mode of the plan layer.
RSpec.describe(MB::Sound::Plan::Installation) do
  around do |ex|
    old = MB::Sound::Plan.precision
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  let(:src) { PlanSpecHelpers::Source }

  describe 'region finding' do
    it 'fuses a chain into one region whose root is the output' do
      g = (src.new(seed: 1) * 2 + src.new(seed: 2) * 3) * 0.5
      inst = MB::Sound::Plan.install(g)
      expect(inst.regions.length).to eq(1)
      expect(inst.regions[0].root).to equal(g)
      expect(inst.regions[0].members.length).to eq(4)
    end

    it 'fuses fan-out inside a region (a node read twice through its Tee)' do
      a = 220.hz.sine
      g = a * src.new(seed: 1) + a * 0.5
      inst = MB::Sound::Plan.install(g)
      expect(inst.regions.length).to eq(1)
      expect(inst.regions[0].members).to include(a)
      expect(inst.regions[0].program.tones.length).to eq(1) # compiled by Plan.install
      expect(a.instance_variable_get(:@started)).to be_falsey # until it plays
      g.sample(64)
      expect(a.instance_variable_get(:@started)).to eq(true)
    end

    it 'makes a node read from outside the region the root of its own region' do
      MB::Sound::Plan.precision = :exact # bit-exact sines
      shared = 110.hz.sine * src.new(seed: 1) * 2
      g1 = shared * 330.hz.sine
      other = shared.proc { |v| v } # an unfused reader outside g1
      inst = MB::Sound::Plan.install(g1)
      expect(inst.regions.map(&:root)).to include(shared)
      expect(inst.regions.find { |r| r.root.equal?(g1) }.members).not_to include(shared)

      ref_shared = 110.hz.sine * src.new(seed: 1) * 2
      ref = [ref_shared * 330.hz.sine, ref_shared.proc { |v| v }]
      [64, 1, 300].each do |n|
        expect(g1.sample(n).to_a).to eq(ref[0].sample(n).to_a)
        expect(other.sample(n).to_a).to eq(ref[1].sample(n).to_a)
      end
    end

    it 'keeps a node with an unread Tee branch out of other regions' do
      a = 330.hz.sine * 1
      a.get_sampler # a branch nobody reads
      g = a * 2 * src.new(seed: 1)
      inst = MB::Sound::Plan.install(g)
      expect(inst.regions.find { |r| r.root.equal?(g) }.members).not_to include(a)
    end

    it 'reads reset triggers as boundary inputs' do
      trig = src.new(kind: :impulses, at: [5]) * 1
      g = 220.hz.sine.reset(trig) * 2
      inst = MB::Sound::Plan.install(g)
      region = inst.regions.find { |r| r.root.equal?(g) }
      expect(region.members).not_to include(trig)
      g.sample(32)
      expect(region.program.inputs.map(&:optional)).to include(true)
    end

    it 'drops regions smaller than Plan.min_nodes' do
      expect(MB::Sound::Plan.install(src.new(seed: 1) * src.new(seed: 2))).to be_nil
    end

    it 'leaves nodes planned by another installation alone' do
      g = 220.hz.sine * 2 * src.new(seed: 1)
      a = MB::Sound::Plan.install(g)
      b = MB::Sound::Plan.install(g.proc { |v| v })
      expect(a.regions.length).to eq(1)
      expect(b).to be_nil
    end

    it 'explains regions and unfused nodes' do
      g = (220.hz.sine * src.new(seed: 1)).proc { |v| v } * 2
      text = MB::Sound::Plan.explain(g)
      expect(text).to include('Unfused nodes', 'a Ruby block', 'PlanSpecHelpers::Source')
    end
  end

  describe 'introspection' do
    it 'never fuses a spied node, and the spy sees every buffer' do
      seen = []
      plan_compare(sizes: [64, 1, 300]) { |c|
        inner = 220.hz.sine * src.new(seed: 1)
        inner.spy { |v| seen << v.length } if c.engine == :c
        inner * 2 + 440.hz.sine
      }
      expect(seen).to eq([64, 1, 300])
    end

    it 'unfuses a node marked with Plan.observe (after a rebuild)' do
      inner = 220.hz.sine * src.new(seed: 1)
      g = inner * 2 + 440.hz.sine
      inst = MB::Sound::Plan.install(g)
      g.sample(10)
      expect(inst.regions.find { |r| r.root.equal?(g) }.members).to include(inner)
      MB::Sound::Plan.observe(inner)
      expect(inst).to be_stale
      g.sample(10)
      expect(inst.regions.find { |r| r.root.equal?(g) }.members).not_to include(inner)
    end

    it 'replans when a new reader takes a branch of a fused node' do
      inner = 220.hz.sine * src.new(seed: 1)
      g = inner * 2 + 440.hz.sine
      inst = MB::Sound::Plan.install(g)
      g.sample(10)
      other = inner * 5
      expect(inst).to be_stale
      g.sample(10)
      expect(inst.regions.map(&:root)).to include(inner)
      expect(other.sample(10)).not_to be_nil
    end
  end

  describe 'check mode' do
    it 'passes for a correct plan' do
      plan_compare(check: :raise) {
        trig = src.new(kind: :impulses, at: [3, 100, 1000])
        (220.hz.ramp.reset(trig) * src.new(seed: 1) + 1.constant * 330.hz.complex_sine.pm(src.new(seed: 2) * 1).real) * 0.5
      }
    end

    it 'compares against the unfused nodes even when the plan is rebuilt during the block' do
      # A boundary input that adds a reader to a fused node while it is
      # read (a structural change in the middle of a block)
      # (read first), so a region read later in the same block (+shared+,
      # rooted separately) rebuilds the installation in the middle of the
      # outer region's block
      shared = 110.hz.sine * 2
      other = shared.proc { |v| v } # an unplanned reader makes +shared+ a root
      grower = Class.new(src) {
        define_method(:sample) { |n| shared.get_sampler if position == 64; super(n) }
      }
      g = (grower.new(seed: 1) * 3 + shared * 0.5 + 330.hz.sine) * 2
      inst = MB::Sound::Plan.install(g, check: :raise)
      expect { [64, 64, 64, 64].each { |n| g.sample(n); other.sample(n) } }.not_to raise_error
      expect(inst.regions.map(&:root)).to include(shared)
    end

    it 'raises when a planned block differs from the unfused graph' do
      g = 220.hz.sine * src.new(seed: 1) * 2
      inst = MB::Sound::Plan.install(g, check: :raise)
      g.sample(16)
      bad = Class.new(MB::Sound::Plan::Op::Mul) { def run_ruby(env, count) = super.tap { env[dst].inplace + 1e-3 } }
      prog = inst.regions[0].program
      mul = prog.ops.grep(MB::Sound::Plan::Op::Mul).last
      # A program with one op off by 1e-3, run by the Ruby mirror
      ops = prog.ops.map { |op| op.equal?(mul) ? bad.new(op.dst, op.node, op.a, op.b) : op }
      tampered = MB::Sound::Plan::Program.new(ops: ops, inputs: prog.inputs, params: prog.params, output: prog.output)
      inst.regions[0].instance_variable_set(:@program, tampered)
      inst.instance_variable_set(:@engine, :ruby)
      expect { g.sample(16) }.to raise_error(MB::Sound::Plan::CheckFailed, /samples differ/)
    end

    it 'warns and stops planning the region with :warn' do
      g = 220.hz.sine * src.new(seed: 1) * 2
      inst = MB::Sound::Plan.install(g, check: :warn, engine: :ruby)
      g.sample(16)
      prog = inst.regions[0].program
      mul = prog.ops.grep(MB::Sound::Plan::Op::Mul).last
      bad = Class.new(MB::Sound::Plan::Op::Mul) { def run_ruby(env, count) = super.tap { env[dst].inplace + 1e-3 } }
      ops = prog.ops.map { |op| op.equal?(mul) ? bad.new(op.dst, op.node, op.a, op.b) : op }
      inst.regions[0].instance_variable_set(:@program, MB::Sound::Plan::Program.new(ops: ops, inputs: prog.inputs, params: prog.params, output: prog.output))
      expect { g.sample(16) }.to output(/Plan check failed/).to_stderr
      expect(inst.regions[0].disabled).to match(/samples differ/)
      expect(g.sample(16)).not_to be_nil
    end
  end

  describe 'fallbacks' do
    it 'replays a block unfused when a boundary input changes type, then recompiles' do
      kinds = [false, false, true, true, false]
      r = plan_compare(sizes: [64, 64, 64, 64, 64], fallbacks: true) { |c|
        s = Class.new(src) {
          define_method(:sample) { |n| v = super(n); kinds[(position / 64) - 1] ? Numo::SComplex.cast(v) * 1i : v }
        }.new(seed: 1)
        s * 3 * 220.hz.sine
      }
      expect(r.regions.first.unfused_blocks).to eq(2) # the two type changes
    end

    it 'can be turned off (Plan.enabled = false)' do
      MB::Sound::Plan.enabled = false
      expect(MB::Sound::Plan.install(220.hz.sine * 2 * src.new(seed: 1))).to be_nil
    ensure
      MB::Sound::Plan.enabled = true
    end
  end

  describe 'Synth and Session' do
    def render_synth(plan)
      MB::Sound::Plan.enabled = plan
      MB::Sound.with_seed(7) {
        s = MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::C3, MB::Sound::E3.n8, MB::Sound::G3, MB::Sound::C4.n2).n4.loop, voices: 3) { |v|
          env = v.amp_env(0.01, 0.1, 0.5, 0.1)
          mod = v.hz.transpose(12).sine.at(1)
          env * v.hz.complex_sine.pm(mod * v.fm_env(0, 0.2, 0.2, 0.1) * 2).real * 0.3 + env * v.hz.ramp * 0.1
        }
        [s, Array.new(40) { |i| s.sample([128, 1, 333, 512][i % 4]).dup }]
      }
    ensure
      MB::Sound::Plan.enabled = true
    end

    it 'gives a Synth the same samples with and without plans' do
      MB::Sound::Plan.precision = :exact
      s, planned = render_synth(true)
      expect(s.plans.compact.length).to eq(s.lanes.length)
      expect(s.plans.compact.flat_map(&:regions).sum(&:planned_blocks)).to be > 0
      _, unplanned = render_synth(false)
      expect(planned.map(&:to_binary)).to eq(unplanned.map(&:to_binary))
    end

    it 'gives a Synth samples within -100 dB with fast sines (the default precision)' do
      MB::Sound::Plan.precision = :fast
      _, planned = render_synth(true)
      _, unplanned = render_synth(false)
      worst = planned.zip(unplanned).map { |a, b| (a - b).abs.max }.max
      expect(worst).to be <= 1e-5
    end

    it 'gives a rendered song the same samples with and without plans' do
      MB::Sound::Plan.precision = :exact
      render = lambda do |plan|
        MB::Sound::Plan.enabled = plan
        MB::Sound.with_seed(3) {
          g = (110.hz.complex_sine.pm(220.hz.sine.at(2) * 0.5.hz.lfo.at(0..1)).real * 0.3 + 10 ** (0.2.hz.triangle.lfo.at(-30..-6) / 20) * 165.hz.saw).softclip
          path = tmp_path("plan_#{plan}.flac")
          MB::Sound.render(path, g, seconds: 0.5, buffer_size: 333)
          MB::Sound.read(path)
        }
      ensure
        MB::Sound::Plan.enabled = true
      end
      a = render.call(true)
      b = render.call(false)
      expect(a.map(&:to_a)).to eq(b.map(&:to_a))
    end
  end
end
