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
end
