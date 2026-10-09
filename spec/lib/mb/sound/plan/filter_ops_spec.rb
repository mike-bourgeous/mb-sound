# Filters as plan ops: each filter node's op (C and Ruby mirror) against the
# node's own #sample, bit for bit, over block sizes from 1 to 800 (see
# spec/support/plan_helpers.rb), with moving parameters, resets, and check
# mode.
RSpec.describe(MB::Sound::Plan, 'filter ops') do
  let(:src) { PlanSpecHelpers::Source }

  def op_names(r)
    r.program.ops.map { |op| op.class.name.split('::').last.to_sym }
  end

  describe 'SVF (Filter::SampleWrapper)' do
    MB::Sound::Filter::SVF::FILTER_TYPE_IDS.each_key do |type|
      it "matches #{type} with moving cutoff, quality, and gain inputs" do
        r = plan_compare(check: :raise) {
          sig = src.new(seed: 1) * 0.8
          sig.filter(type, cutoff: src.new(seed: 2, scale: 1500, offset: 2000), quality: src.new(seed: 3, scale: 2, offset: 2.5),
                     gain: src.new(seed: 4, scale: 0.5, offset: 1.5))
        }
        expect(op_names(r)).to include(:FilterSvf)
      end
    end

    it 'matches with constant parameters and a numeric gain (params, a gain constant)' do
      r = plan_compare(check: :raise) {
        (src.new(seed: 5) * 1).filter(:peak, cutoff: 900, quality: 1.5, gain: 2.5).filter(:lowpass, cutoff: 3000, quality: 0.7) * 1
      }
      expect(op_names(r).count(:FilterSvf)).to eq(2)
    end

    it 'matches parameters at their limits (cutoffs below 1 Hz and above 0.49 of the rate, negative and NaN-free extremes)' do
      plan_compare(check: :raise) {
        (src.new(seed: 6) * 1).filter(:bandpass, cutoff: src.new(seed: 7, scale: 30000, offset: 0), quality: src.new(seed: 8, scale: 3, offset: 0)) * 1
      }
    end

    it 'follows a filter reset and a constant change between blocks' do
      r = plan_compare(check: :raise) { |c|
        cut = MB::Sound::GraphNode::Constant.new(1200, sample_rate: 48000)
        g = (src.new(seed: 9) * 1).filter(:lowpass, cutoff: cut, quality: 4)
        c.before_block(4) { g.reset(0.3) }
        c.before_block(7) { cut.constant = 5000 }
        g * 1
      }
      expect(op_names(r)).to include(:FilterSvf)
    end

    it 'remembers the last parameters on the filter as the node does' do
      a = (src.new(seed: 1) * 1).filter(:highshelf, cutoff: src.new(seed: 2, scale: 100, offset: 900), quality: 0.7, gain: src.new(seed: 3, scale: 0.2, offset: 1))
      b = (src.new(seed: 1) * 1).filter(:highshelf, cutoff: src.new(seed: 2, scale: 100, offset: 900), quality: 0.7, gain: src.new(seed: 3, scale: 0.2, offset: 1))
      ga = a * 1
      gb = b * 1
      MB::Sound::Plan.install(gb)
      5.times { |i| ga.sample(100 + i); gb.sample(100 + i) }
      fa = a.base_filter
      fb = b.base_filter
      expect([fb.cutoff, fb.quality, fb.gain, fb.state]).to eq([fa.cutoff, fa.quality, fa.gain, fa.state])
    end

    it 'leaves other wrapped filters unfused with a reason' do
      g = (src.new(seed: 1) * 1).filter(MB::Sound::Filter::FirstOrder.new(:lowpass, 48000, 500)) * 1
      expect(MB::Sound::Plan.explain(g)).to include('a Filter::FirstOrder filter')
    end
  end

  describe 'cookbook biquad (structure: :biquad)' do
    MB::Sound::Filter::Cookbook::FILTER_TYPES.each do |type|
      gain = MB::Sound::Filter::SVF::GAIN_TYPES.include?(type) ? 2.0 : nil

      it "matches #{type} with moving cutoff and quality" do
        r = plan_compare(check: :raise) {
          (src.new(seed: 1) * 0.8).filter(type, cutoff: src.new(seed: 2, scale: 1500, offset: 2000), quality: src.new(seed: 3, scale: 2, offset: 2.5),
                                          gain: gain, structure: :biquad) * 1
        }
        expect(op_names(r)).to include(:FilterBiquad)
      end
    end

    it 'matches constant parameters, cutoffs past the limits, and a reset' do
      plan_compare(check: :raise) { |c|
        s = src.new(seed: 4) * 1
        a = s.filter(:lowpass, cutoff: 700, quality: 0.7, structure: :biquad)
        b = s.filter(:highpass, cutoff: src.new(seed: 5, scale: 30000, offset: 0), quality: src.new(seed: 6, scale: 1, offset: 0), structure: :biquad)
        c.before_block(5) { a.reset(0.25) }
        a + b * 0.1
      }
    end
  end

  describe 'four-pole (GraphNode::FourPole)' do
    fp = MB::Sound::Filter::FourPole

    fp::MODES.each_key do |mode|
      it "matches #{mode} with moving cutoff and resonance" do
        r = plan_compare(check: :raise) {
          (src.new(seed: 1) * 0.8).lp4(src.new(seed: 2, scale: 1500, offset: 2000), resonance: src.new(seed: 3, scale: 0.5, offset: 0.5), mode: mode) * 1
        }
        expect(op_names(r)).to include(:FourPole)
      end

      it "matches #{mode} self-oscillating" do
        plan_compare(check: :raise) {
          (src.new(seed: 4) * 0.1).lp4(src.new(seed: 5, scale: 400, offset: 900), resonance: src.new(seed: 6, scale: 0.1, offset: 0.92), mode: mode, self_oscillate: true) * 1
        }
      end
    end

    fp::MODES.keys.product(fp::DRIVE_MODES.keys, fp::CLIPS.keys).each do |mode, drive_mode, clip|
      next if mode == :diode && drive_mode == :stages
      next if clip != :soft && drive_mode != :feedback

      it "matches #{mode} with drive_mode #{drive_mode}, clip #{clip}" do
        plan_compare(check: :raise) {
          (src.new(seed: 7) * 2).lp4(src.new(seed: 8, scale: 1000, offset: 1500), resonance: 0.8, mode: mode, drive: 2.5, drive_mode: drive_mode, clip: clip) * 1
        }
      end
    end

    it 'matches constant parameters, the linear curve, a quality node, and an unnormalized diode ladder' do
      r = plan_compare(check: :raise) {
        s = src.new(seed: 9) * 1
        s.lp4(700, resonance: 0.5, resonance_curve: :linear) + s.lp4(1200, quality: src.new(seed: 10, scale: 2, offset: 3)) +
          s.lp4(900, resonance: 0.6, mode: :diode, normalize: false)
      }
      expect(op_names(r).count(:FourPole)).to eq(3)
    end

    it 'follows a reset between blocks and keeps the last parameter values for an ending input' do
      plan_compare(check: :raise) { |c|
        g = (src.new(seed: 11) * 1).lp4(src.new(seed: 12, scale: 500, offset: 1000, ends_at: 2000), resonance: 0.7)
        c.before_block(6) { g.reset(0.2) }
        g * 1
      }
    end
  end
end
