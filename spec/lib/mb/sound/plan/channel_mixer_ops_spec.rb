# ChannelMixer as a plan node (MB::Sound::Plan::MultiDescribable): a mixer
# with real number gains roots a region computing every output (Op::Mix
# rows, Op::Output copies), so a unison's oscillators fuse with their pitch
# and the mix; samples bit for bit as unplanned (see
# spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::GraphNode::ChannelMixer, 'plan ops') do
  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  let(:src) { PlanSpecHelpers::Source }

  # The region rooted at a ChannelMixer in a plan_compare Result.
  def mixer_region(r, engine = :c)
    r.regions(engine).find { |reg| reg.root.is_a?(MB::Sound::GraphNode::ChannelMixer) }
  end

  describe 'Op::Mix' do
    def real(n, seed)
      Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(n).seq * (0.37 * seed) + seed) * 1.7)
    end

    [1, 3, 128, 800].each do |n|
      it "gives MB::FastSound.matrix_mix's samples in C and the Ruby mirror, weights 0, 1, -1, and others included (#{n} samples)" do
        xs = [real(n, 1), real(n, 2), real(n, 3), real(n, 4)]
        xs[2][0] = Float::NAN
        xs[3][n - 1] = -Float::INFINITY if n > 1
        weights = [[0.3, 1, -1, 0], [0, 0.7071067811865476, -2.5, 1e-3], [1, 1, 1, 1]]

        expected = MB::FastSound.matrix_mix(Numo::DFloat.cast(weights), xs, Array.new(3) { Numo::SFloat.zeros(n) })
        weights.each_with_index do |row, j|
          b = MB::Sound::Plan::Builder.new
          ins = xs.map { b.input(:real, source: nil, handles: [], reason: 'test') }
          out = b.mix(ins, row)
          prog = MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: out)

          got = Numo::SFloat.zeros(n)
          prog.run(n, xs, [], got)
          expect(got.to_binary).to eq(expected[j].to_binary), "row #{j} in C"
          expect(prog.run_ruby(n, xs, []).to_binary).to eq(expected[j].to_binary), "row #{j} in Ruby"
        end
      end
    end

    it 'lowers to words that do not depend on the weights (lanes with other gains group)' do
      words = [[0.3, 1, -1], [0, 0.5, 2]].map { |row|
        b = MB::Sound::Plan::Builder.new
        ins = Array.new(3) { b.input(:real, source: nil, handles: [], reason: 'test') }
        MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: b.mix(ins, row)).signature
      }
      expect(words.uniq.length).to eq(1)
    end

    it 'refuses complex terms' do
      b = MB::Sound::Plan::Builder.new
      x = b.input(:complex, source: nil, handles: [], reason: 'test')
      expect { b.mix([x], [1]) }.to raise_error(MB::Sound::Plan::Unsupported, /complex/)
    end

    it 'raises for bad mix words instead of reading out of bounds' do
      b = MB::Sound::Plan::Builder.new
      ins = Array.new(2) { b.input(:real, source: nil, handles: [], reason: 'test') }
      prog = MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: b.mix(ins, [0.5, 0.25]))
      words, scalars, objects = prog.lower
      at = words.to_a.index(MB::Sound::Plan::Program::OPCODES[:mix])
      bad = words.dup
      bad[at + 2] = 1000
      expect {
        MB::Sound::FastPlan.run(bad, scalars, objects, [Numo::SFloat.zeros(4), Numo::SFloat.zeros(4)], [], Numo::SFloat.zeros(8), Numo::SFloat.zeros(4), 4)
      }.to raise_error(ArgumentError)
    end
  end

  describe 'unison' do
    def unison(n = 4, spread: 0.6, mix: 1)
      MB::Sound.with_seed(5) { 220.hz.unison(n, detune: 0.2, spread: spread, mix: mix) { |p, _i| p.saw } }
    end

    it 'fuses the oscillators and the mix into one region computing both outputs' do
      r = plan_compare { |_c|
        l, rt = unison.to_a
        l + rt * 0.5
      }
      reg = mixer_region(r)
      expect(reg).not_to be_nil
      expect(reg.members.count { |m| m.is_a?(MB::Sound::Tone) }).to eq(4)
      names = reg.program.ops.map { |op| op.class.name.split('::').last }
      expect(names.count('Mix')).to eq(2)
      expect(names.count('Output')).to eq(1)
      expect(names.count('Tone')).to eq(4)
      expect(reg.planned_blocks).to be > 0
    end

    it 'matches with the right output read before the left' do
      plan_compare { |_c|
        l, rt = unison.to_a
        rt * 0.25 + l
      }
    end

    it 'matches a mono unison feeding more ops, with a mix and peak normalization' do
      r = plan_compare { |_c|
        (MB::Sound.with_seed(8) { 110.hz.unison(5, detune: 0.3, mix: 0.4, normalize: :peak) { |p, _i| p.square } }) * 0.5
      }
      expect(mixer_region(r).program.ops.grep(MB::Sound::Plan::Op::Output)).to be_empty
    end

    it 'matches in check mode (the outputs compared each block)' do
      plan_compare(check: :raise) { |_c|
        l, rt = unison(3).to_a
        l - rt
      }
    end

    it 'ends with an input that ends, on the same block' do
      r = plan_compare(fallbacks: 1) { |_c|
        a = src.new(seed: 2, ends_at: 1000) * 0.5
        b = src.new(seed: 3) * 0.25
        m = MB::Sound::GraphNode::ChannelMixer::Unison.new([a, b], slots: [-1, 1], spread: 1, stereo: true)
        m.outputs[0] + m.outputs[1]
      }
      expect(r.outputs[:unfused].compact.sum(&:length)).to eq(1000)
    end

    it 'fuses a unison with a moving spread (Op::PanGain per copy, plan-fusion-2)' do
      r = plan_compare { |_c|
        l, rt = MB::Sound.with_seed(5) { 220.hz.unison(3, detune: 0.2, spread: 0.3.hz.lfo.at(0..1)) { |p, _i| p.saw } }.to_a
        l + rt * 0.5
      }
      reg = mixer_region(r)
      expect(reg).not_to be_nil
      expect(reg.program.ops.count { |op| op.is_a?(MB::Sound::Plan::Op::PanGain) }).to eq(6)
    end

    it 'fuses a moving spread past full width and below zero (positions clipped), also in check mode' do
      plan_compare(check: :raise) { |_c|
        spread = src.new(kind: :steps, seed: 4, every: 70, scale: 1.5) * 1
        m = MB::Sound::GraphNode::ChannelMixer::Unison.new([src.new(seed: 2) * 0.5, src.new(seed: 3) * 0.25, src.new(seed: 5) * 1],
                                                            slots: [-1, 0.4, 0], spread: spread, stereo: true)
        m.outputs[0] - m.outputs[1] * 0.5
      }
    end

    it 'leaves a unison with a moving mix unfused, with a reason' do
      graph = MB::Sound.with_seed(5) { 220.hz.unison(3, detune: 0.2, spread: 0.5, mix: 0.3.hz.lfo.at(0..1)) { |p, _i| p.saw } }
      text = MB::Sound::Plan.explain(graph.to_a[0] + graph.to_a[1])
      expect(text).to include('a moving unison mix')
    end

    it 'names the outputs as computed in the mixer region in Plan.explain' do
      l, rt = unison.to_a
      text = MB::Sound::Plan.explain(l.lp4(800) + rt.lp4(900))
      expect(text).to include('mix(', 'output 1 =', 'computed in its region')
    end
  end

  describe 'other mixing laws' do
    # Members feeding the mixer (so it has a region of more than one node).
    def stereo_input(seed = 1)
      MB::Sound.stereo(src.new(seed: seed) * 0.8, src.new(seed: seed + 1, kind: :steps) * 0.6)
    end

    {
      pan: ->(s) { (s[0] * 0.5).pan(0.3) },
      pan_linear: ->(s) { (s[0] * 0.5).pan(-0.7, law: :linear) },
      pan_minus_4_5db: ->(s) { (s[0] * 0.5).pan(0.2, law: :minus_4_5db) },
      balance: ->(s) { s.balance(-0.4) },
      width: ->(s) { s.width(1.6) },
      mid_side: ->(s) { s.mid_side },
      swap: ->(s) { s.swap },
      matrix: ->(s) { MB::Sound.channels(s[0], s[1], s[0] * 0.3).matrix([[1, 0, -1], [0.25, -1, 2], [0, 0, 0]]) },
    }.each do |name, make|
      it "matches #{name} bit for bit" do
        r = plan_compare { |_c|
          outs = make.call(stereo_input).to_a
          outs.each_with_index.map { |o, i| o * (i + 1) }.reduce(:+)
        }
        expect(mixer_region(r)).not_to be_nil
      end
    end

    it 'matches mono (one output)' do
      r = plan_compare { |_c| stereo_input.mono * 2 }
      expect(mixer_region(r)).not_to be_nil
    end

    {
      pan: ->(s, pos) { (s[0] * 0.5).pan(pos) },
      pan_linear: ->(s, pos) { (s[0] * 0.5).pan(pos, law: :linear) },
      pan_minus_4_5db: ->(s, pos) { (s[0] * 0.5).pan(pos, law: :minus_4_5db) },
      balance: ->(s, pos) { s.balance(pos) },
    }.each do |name, make|
      it "matches a moving #{name} (Op::PanGain), positions beyond -1..1 included, also in check mode" do
        r = plan_compare(check: :raise) { |_c|
          pos = src.new(kind: :steps, seed: 6, every: 45, scale: 1.4) * 1
          outs = make.call(stereo_input, pos).to_a
          outs[0] + outs[1] * 0.5
        }
        expect(mixer_region(r).program.ops.count { |op| op.is_a?(MB::Sound::Plan::Op::PanGain) }).to eq(2)
      end
    end

    it 'fuses an autopan LFO with the pan (the keys presets)' do
      r = plan_compare { |_c| (src.new(seed: 1) * 0.5).pan(4.6.hz.lfo.at(0.22)).to_a.reduce(:+) }
      expect(mixer_region(r).members.count { |m| m.is_a?(MB::Sound::Tone) }).to eq(1)
    end

    it 'runs moving pans with the Ruby mirror (PanLaws)' do
      r = plan_compare(engines: [:ruby]) { |_c|
        pos = src.new(kind: :steps, seed: 7, every: 30, scale: 1.2) * 1
        (src.new(seed: 1) * 0.5).pan(pos, law: :minus_4_5db).to_a.reduce(:+) + stereo_input.balance(pos * 0.9).to_a.reduce(:+)
      }
      ops = r.regions(:ruby).flat_map { |reg| reg.program.ops }
      expect(ops.count { |op| op.is_a?(MB::Sound::Plan::Op::PanGain) }).to eq(4)
    end

    it 'leaves complex gains unfused' do
      text = MB::Sound::Plan.explain((src.new(seed: 1) * 0.5).place(x: 0.3, y: 0.2).to_a.reduce(:+))
      expect(text).to include('complex gains')
    end
  end

  describe 'synth lanes' do
    def make_synth(lanes:, voices: 3)
      old = MB::Sound::Plan.lanes
      MB::Sound::Plan.lanes = lanes
      MB::Sound.seed(0)
      MB::Sound.synth('spec/test_data/dense_modulated.mid', voices: voices, spares: 1, skip_idle: false) { |v|
        saws = v.hz.glide(30.ms).unison(4, detune: 0.25, spread: 0.5) { |p, _i| p.saw }
        saws.lp4(v.cutoff(1500), resonance: 0.3) * v.amp_env
      }
    ensure
      MB::Sound::Plan.lanes = old
    end

    def render(synth, sizes)
      out = []
      sizes.each do |n|
        bufs = synth.outputs.map { |o| o.sample(n) }
        break if bufs.any?(&:nil?)

        bufs.each { |b| out.concat(b.to_a) }
      end
      out
    end

    it 'groups the unison regions across lanes and gives the samples of each lane alone and unplanned' do
      sizes = [128, 1, 37, 512, 800, 64, 255] * 4
      s = make_synth(lanes: true)
      a = render(s, sizes)
      groups = s.lane_groups.groups
      mixer_groups = groups.select { |g| g.members[0].root.is_a?(MB::Sound::GraphNode::ChannelMixer) }
      expect(mixer_groups.map { |g| g.members.length }.max).to eq(4)
      expect(mixer_groups.sum(&:lane_runs)).to be > 0

      b = render(make_synth(lanes: false), sizes)
      old = MB::Sound::Plan.enabled
      begin
        MB::Sound::Plan.enabled = false
        c = render(make_synth(lanes: false), sizes)
      ensure
        MB::Sound::Plan.enabled = old
      end
      expect(a.length).to be > 5000
      expect(a).to eq(b)
      expect(a).to eq(c)
    end
  end
end
