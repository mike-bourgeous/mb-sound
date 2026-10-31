# Unison::Detune as a plan node (MB::Sound::Plan::MultiDescribable,
# fix-alloc-1): in :exact mode it roots a region computing every copy's
# frequency (one Op::UnisonCopy per copy), so a synth voice's unison runs
# fused and its lanes group, as before gen-midi-2 gave fixed detunes this
# node (render_allocations_spec's unison graph: 81 -> 30 objects per
# buffer).  Samples bit for bit as unplanned (see
# spec/support/plan_helpers.rb).
RSpec.describe(MB::Sound::Unison::Detune, 'plan ops') do
  let(:src) { PlanSpecHelpers::Source }

  # The region rooted at a Detune in a plan_compare Result.
  def detune_region(r, engine = :c)
    r.regions(engine).find { |reg| reg.root.is_a?(MB::Sound::Unison::Detune) }
  end

  describe 'Op::UnisonCopy' do
    FRACTIONS = [-1.0, -0.37, 0.0, 0.5, 1.0].freeze

    def detune_buffer(n, kind)
      case kind
      when :constant
        Numo::SFloat.new(n).fill(0.2)
      when :moving
        Numo::SFloat.cast(Numo::NMath.sin(Numo::DFloat.new(n).seq * 0.37) * 0.8 + 0.9)
      when :odd
        d = Numo::SFloat.cast(Numo::DFloat.new(n).seq * 0.01)
        d[0] = -0.0
        d[n / 2] = Float::NAN if n > 2
        d[n - 1] = 1e3 if n > 1
        d
      end
    end

    [1, 3, 128, 800].each do |n|
      %i[constant moving odd].each do |kind|
        it "gives FastUnison.exact's rows in C and the Ruby mirror (#{kind} detune, #{n} samples, register and scalar frequencies)" do
          d = detune_buffer(n, kind)
          f = Numo::SFloat.cast(Numo::DFloat.new(n).seq(110, 0.73))
          [f, 220.123456789].each do |freq|
            expected = Numo::SFloat.zeros(FRACTIONS.length, n)
            MB::Sound::FastUnison.exact(expected, freq, d, FRACTIONS)
            if kind == :constant
              scaled = Numo::SFloat.zeros(FRACTIONS.length, n)
              MB::Sound::FastUnison.scale(scaled, freq, FRACTIONS.map { |a| Math.exp(a * (d[0] * MB::Sound::Unison::Detune::LOG_SEMITONE)) })
              expect(scaled.to_binary).to eq(expected.to_binary)
            end

            FRACTIONS.each_with_index do |a, i|
              b = MB::Sound::Plan::Builder.new
              dv = b.input(:real, source: nil, handles: [], reason: 'test')
              inputs = [d]
              fv = if freq.is_a?(Numeric)
                freq
              else
                inputs << freq
                b.input(:real, source: nil, handles: [], reason: 'test')
              end
              out = b.unison_copy(dv, fv, a)
              prog = MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: out)

              got = Numo::SFloat.zeros(n)
              prog.run_c(n, inputs, [], got)
              expect(got.to_binary).to eq(expected[i, true].to_binary), "copy #{i} in C (#{freq.class})"
              expect(prog.run_ruby(n, inputs, []).to_binary).to eq(expected[i, true].to_binary), "copy #{i} in Ruby (#{freq.class})"
            end
          end
        end
      end
    end

    it 'lowers to words that do not depend on the fraction or a scalar frequency (lanes with other layouts group)' do
      words = [[-1.0, 110.0], [0.25, 220.0]].map { |a, f|
        b = MB::Sound::Plan::Builder.new
        d = b.input(:real, source: nil, handles: [], reason: 'test')
        MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: b.unison_copy(d, f, a)).signature
      }
      expect(words.uniq.length).to eq(1)
    end

    it 'raises for bad unison words instead of reading out of bounds' do
      b = MB::Sound::Plan::Builder.new
      d = b.input(:real, source: nil, handles: [], reason: 'test')
      prog = MB::Sound::Plan::Program.new(ops: b.ops, inputs: b.inputs, params: b.params, output: b.unison_copy(d, 110.0, 0.5))
      words, scalars, objects = prog.lower
      at = words.to_a.index(MB::Sound::Plan::Program::OPCODES[:unison])
      [[3, 1000], [4, scalars.length]].each do |offset, value|
        bad = words.dup
        bad[at + offset] = value
        expect {
          MB::Sound::FastPlan.run(bad, scalars, objects, [Numo::SFloat.zeros(4)], [], Numo::SFloat.zeros(8), Numo::SFloat.zeros(4), 4)
        }.to raise_error(ArgumentError, /unison/)
      end
    end
  end

  describe 'Detune regions' do
    def unison(detune, count = 5, **opts)
      MB::Sound.with_seed(5) { 220.hz.unison(count, detune: detune, **opts) { |p, _i| p.saw } }
    end

    it 'fuses a fixed detune: one UnisonCopy per copy, reading the constant as a param' do
      r = plan_compare { |_c| unison(0.2) * 0.5 }
      reg = detune_region(r)
      expect(reg).not_to be_nil
      expect(reg.program.ops.grep(MB::Sound::Plan::Op::UnisonCopy).length).to eq(5)
      expect(reg.program.params.length).to eq(1)
      expect(reg.planned_blocks).to be > 0
    end

    it 'fuses a moving detune (an LFO), also in check mode' do
      r = plan_compare(check: :raise) { |_c| unison(0.7.hz.lfo.at(0.05..0.6), 4) }
      expect(detune_region(r)).not_to be_nil
    end

    it 'matches a detune that changes in steps and a Notes base frequency in a synth voice' do
      plan_compare { |_c|
        d = src.new(kind: :steps, seed: 4, every: 70, scale: 0.4) * 1
        MB::Sound.with_seed(2) { (220.hz.transpose(src.new(kind: :steps, seed: 6, every: 90, scale: 3) * 1)).unison(3, detune: d) { |p, _| p.saw } }
      }
    end

    it 'ends with a base frequency that ends, on the same block' do
      r = plan_compare(fallbacks: 1) { |_c|
        f = src.new(seed: 2, ends_at: 1000) * 30 + 200
        det = MB::Sound::Unison::Detune.new(f, MB::Sound::GraphNode::Constant.new(0.3, smoothing: false, sample_rate: 48000), fractions: [-1, 0.2, 1])
        det.outputs[0] + det.outputs[1] * 0.5 - det.outputs[2] * 0.25
      }
      expect(r.outputs[:unfused].compact.sum(&:length)).to eq(1000)
    end

    it 'leaves :interp mode unfused, with a reason' do
      text = MB::Sound::Plan.explain(unison(0.2, 3, detune_mode: :interp))
      expect(text).to include('detune_mode: :interp')
    end
  end

  describe 'synth lanes' do
    def make_synth(plans:)
      old = MB::Sound::Plan.enabled
      MB::Sound::Plan.enabled = plans
      MB::Sound.seed(0)
      MB::Sound.synth('spec/test_data/dense_modulated.mid', voices: 2, spares: 1) { |v|
        v.hz.unison(7, detune: 0.2) { |p, _| p.saw.reset(v.key_trigger) } * v.amp_env(0.005, 0.1, 0.6, 0.05)
      }
    ensure
      MB::Sound::Plan.enabled = old
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

    it 'groups the Detune regions across lanes (lanes no longer skip around an unfused Detune) and gives the unplanned samples' do
      sizes = [128, 1, 37, 512, 800, 64, 255] * 4
      s = make_synth(plans: true)
      a = render(s, sizes)
      groups = s.lane_groups&.groups || []
      detune_groups = groups.select { |g| g.members[0].root.is_a?(MB::Sound::Unison::Detune) }
      expect(detune_groups.map { |g| g.members.length }.max).to eq(3)
      expect(detune_groups.sum(&:lane_runs)).to be > 0

      old = MB::Sound::Plan.enabled
      begin
        MB::Sound::Plan.enabled = false
        b = render(make_synth(plans: false), sizes)
      ensure
        MB::Sound::Plan.enabled = old
      end
      expect(a.length).to be > 5000
      expect(a).to eq(b)
    end
  end
end
