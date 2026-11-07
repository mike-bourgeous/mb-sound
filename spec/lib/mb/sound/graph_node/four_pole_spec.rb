RSpec.describe(MB::Sound::GraphNode::FourPole, :check_shared) do
  let(:saw) { 110.hz.saw }

  def filtered(fc, r, input, **opts)
    f = MB::Sound::Filter::FourPole.new(**opts)
    f.dynamic_process(input, cutoff: fc, resonance: r)
  end

  describe 'GraphNode#lp4' do
    it 'gives the same samples as the filter object' do
      input = 110.hz.saw.sample(1000).dup
      node = 110.hz.saw.lp4(800, resonance: 0.6)
      expect(node.sample(1000)).to eq(filtered(800.0, 0.6, input))
    end

    it 'reads cutoff and resonance nodes per sample' do
      cutoff = 3.hz.lfo.at(200..4000)
      res = 2.hz.lfo.at(0..1)
      node = 110.hz.saw.lp4(cutoff, resonance: res, drive: 2, mode: :bp2)
      expect(node.sources.keys).to eq([:input, :cutoff, :resonance])

      out = node.sample(800)
      input = 110.hz.saw.sample(800).dup
      fc = 3.hz.lfo.at(200..4000).sample(800).dup
      rr = 2.hz.lfo.at(0..1).sample(800).dup
      expect(out).to eq(filtered(fc, rr, input, drive: 2, mode: :bp2))
    end

    it 'works at audio rate (filter FM)' do
      node = 110.hz.saw.lp4(220.hz.at(1000) + 1500, resonance: 0.5)
      out = node.sample(4800)
      expect(out.isfinite.all?).to eq(true)
      expect(out.abs.max).to be > 0.1
    end

    it 'takes a Pitch as the cutoff frequency' do
      node = 110.hz.saw.lp4(800.hz, resonance: 0.3)
      expect(node.cutoff).to eq(800.0)
      expect(node.kernel_filter.cutoff).to eq(800.0)
    end

    it 'has aliases four_pole and lowpass4' do
      expect(saw.four_pole(500)).to be_a(MB::Sound::GraphNode::FourPole)
      expect(saw.lowpass4(500).kernel_filter.mode).to eq(:lp4)
    end

    it 'passes the options to the filter' do
      f = saw.lp4(500, resonance: 1, self_oscillate: true, mode: :hp2, compensation: 0.1).kernel_filter
      expect(f).to be_self_oscillate
      expect(f.drive).to eq(1.0)
      expect(f.mode).to eq(:hp2)
      expect(f.compensation).to eq(0.1)
    end

    it 'does not modify a shared input buffer' do
      src = 110.hz.saw
      a = src.lp4(500, resonance: 0.5)
      b = src * 1
      x = a.sample(800).dup
      y = b.sample(800).dup
      expect(y).to eq(110.hz.saw.sample(800))
      expect(x).to eq(filtered(500.0, 0.5, y))
    end

    it 'ends when its input ends' do
      node = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(100)]).lp4(1000)
      expect(node.sample(100).length).to eq(100)
      expect(node.sample(100)).to be_nil
    end

    it 'keeps the last value of a parameter node that ended' do
      cutoff = MB::Sound::ArrayInput.new(data: [Numo::SFloat[300, 400, 500]])
      node = 1.constant.lp4(cutoff)
      node.sample(5)
      expect(node.kernel_filter.cutoff).to eq(500)
      node.sample(5)
      expect(node.kernel_filter.cutoff).to eq(500)
    end

    it 'works per channel on bundles' do
      out = MB::Sound.stereo(110.hz.saw, 165.hz.saw).lp4(MB::Sound.channels(500, 900), resonance: 0.5)
      expect(out).to be_a(MB::Sound::GraphNode::Channels)
      expect(out.map { |c| c.kernel_filter.cutoff }).to eq([500.0, 900.0])
    end

    it 'follows sample rate changes' do
      node = saw.lp4(1000)
      node.sample_rate = 96000
      expect(node.sample_rate).to eq(96000)
      expect(node.kernel_filter.sample_rate).to eq(96000)
      expect(node.at_rate(44100).kernel_filter.sample_rate).to eq(44100)
    end

    it 'resets the filter state' do
      node = 0.5.constant.lp4(100, resonance: 0.5)
      node.reset(0.5)
      k = MB::Sound::Filter::FourPole.resonance_curve(0.5) * 3.9
      expected = 0.5 * (1 + 0.375 * k) / (1 + k)
      expect(node.sample(10).to_a).to all(be_within(1e-6).of(expected))
    end

    it 'works with notes' do
      v = MB::Sound.seq(MB::Sound::C4.n4).notes
      node = v.hz.saw.lp4(v.cutoff(400), resonance: 0.5) * v.amp_env
      out = node.sample(4800)
      expect(out.abs.max).to be > 0.05
    end
  end

  describe 'GraphNode#filter' do
    it 'makes a four-pole filter for :lp4 and the other modes' do
      expect(saw.filter(:lp4, cutoff: 500, resonance: 0.5)).to be_a(MB::Sound::GraphNode::FourPole)
      expect(saw.filter(:four_pole, cutoff: 500).kernel_filter.mode).to eq(:lp4)
      expect(saw.filter(:hp4, cutoff: 500).kernel_filter.mode).to eq(:hp4)
    end

    it 'knows every four-pole mode' do
      expect(MB::Sound::GraphNode::FilterMethods::FOUR_POLE_TYPES - [:four_pole]).to eq(MB::Sound::Filter::FourPole::MODES.keys)
    end

    it 'maps quality for four-pole filters to the same gain at the cutoff' do
      node = saw.filter(:lp4, cutoff: 500, quality: 4)
      expect(node.resonance).to be_within(1e-12).of(MB::Sound::Filter::FourPole.quality_to_resonance(4))
      f = node.kernel_filter
      f.resonance = node.resonance
      at_cutoff = f.response(2 * Math::PI * 500 / 48000).abs / f.response(0).abs
      expect(at_cutoff).to be_within(0.005).of(4)

      hw = saw.lp4(500, quality: 4, tuning: :hardware)
      expect(hw.resonance).to be_within(1e-12).of(Math.log(16) / Math.log(196))
      g = hw.kernel_filter
      g.resonance = hw.resonance
      expect(g.response(2 * Math::PI * 500 / 48000).abs / g.response(0).abs).to be_within(1e-6).of(4)

      lin = saw.lp4(500, quality: 4, resonance_curve: :linear)
      lin.kernel_filter.resonance = lin.resonance
      expect(lin.kernel_filter.loop_gain).to be_within(1e-9).of(f.loop_gain)

      expect(saw.lp4(500, quality: 0.1).resonance).to eq(0)
      expect(saw.lp4(500, quality: 100).resonance).to eq(1)
      expect { saw.lp4(500, quality: 1, resonance: 1) }.to raise_error(ArgumentError, /not both/)
    end

    it 'takes a quality node such as Notes#quality' do
      v = MB::Sound.seq(MB::Sound::C4.n4).notes
      node = v.hz.saw.lp4(v.cutoff(400), quality: v.quality(4))
      expect(node.resonance.sample(10).to_a.uniq.map { |r| r.round(5) }).to eq([MB::Sound::Filter::FourPole.quality_to_resonance(4).round(5)])
      expect(node.sample(800).isfinite.all?).to eq(true)
    end

    it 'rejects gain for four-pole filters and resonance for others' do
      expect { saw.filter(:lp4, cutoff: 500, gain: 4) }.to raise_error(ArgumentError, /gain/)
      expect { saw.filter(:highpass, cutoff: 500, resonance: 0.5) }.to raise_error(ArgumentError, /resonance/)
      expect { saw.filter(:lp4) }.to raise_error(ArgumentError, /Cutoff/)
    end

    describe ':lowpass with lp4\'s resonance and slope: (reese-slope-1)' do
      let(:fp) { MB::Sound::Filter::FourPole }

      it 'maps lp4\'s resonance to the 2-pole quality with lp4\'s gain at the cutoff (the inverse of quality_to_resonance)' do
        expect(fp.resonance_to_quality(0)).to be_within(1e-9).of(0.5)
        { 0.15 => 0.58, 0.2 => 0.89, 0.25 => 1.56, 0.5 => 5.28 }.each do |r, q|
          expect(fp.resonance_to_quality(r)).to be_within(0.01).of(q), r.to_s
        end
        (12..100).each { |i| expect(fp.quality_to_resonance(fp.resonance_to_quality(i / 100.0))).to be_within(1e-4).of(i / 100.0) }
        (1..20).each { |i| expect(fp.resonance_to_quality(fp.quality_to_resonance(i))).to be_within(i * 1e-3).of(i) }
        expect(fp.resonance_to_quality(0.4, tuning: :hardware)).to be_within(1e-12).of(196**0.4 / 4)
        expect(fp.resonance_to_quality(Numo::SFloat[0, 0.25, 0.5]).to_a).to eq([0, 0.25, 0.5].map { |r| fp.resonance_to_quality(r).to_f }.map { |q| Numo::SFloat[q][0] })

        # lp4's response at its cutoff matches the 2-pole's (q) at every resonance
        [0, 0.15, 0.25, 0.5, 0.8].each do |r|
          f = fp.new(cutoff: 500, resonance: r)
          at_cutoff = f.response(2 * Math::PI * 500 / 48000).abs / f.response(0).abs
          expect(at_cutoff).to be_within(0.005 * at_cutoff).of(fp.resonance_to_quality(r)), r.to_s
        end
      end

      it 'builds an SVF lowpass at the mapped quality, from a number or a node' do
        node = saw.filter(:lowpass, cutoff: 900, resonance: 0.25)
        expect(node).to be_a(MB::Sound::Filter::SampleWrapper)
        plain = 110.hz.saw.filter(:lowpass, cutoff: 900, quality: fp.resonance_to_quality(0.25))
        expect(node.sample(800)).to eq(plain.sample(800))

        knob = 0.25.constant.named('res')
        moving = 110.hz.saw.filter(:lowpass, cutoff: 900, resonance: knob)
        q = MB::Sound::GraphNode::FourPole.resonance_quality(0.3.constant)
        expect(q).to be_a(MB::Sound::GraphNode::QualityResonance)
        expect(q.sample(4).to_a.map { |v| v.round(4) }).to eq([fp.resonance_to_quality(0.3).round(4)] * 4)
        expect((moving.sample(800) - 110.hz.saw.filter(:lowpass, cutoff: 900, resonance: 0.25).sample(800)).abs.max).to be < 1e-5
        expect { saw.filter(:lowpass, cutoff: 900, resonance: 0.2, quality: 1) }.to raise_error(ArgumentError, /not both/)
      end

      it 'picks lp4 (exactly) with slope: 24 and the 2-pole with 12, read from a number, param, or knob when it builds' do
        expect(saw.filter(:lowpass, cutoff: 900, resonance: 0.3, slope: 24)).to be_a(MB::Sound::GraphNode::FourPole)
        lp4 = 110.hz.saw.lp4(900, resonance: 0.3).sample(2000).dup
        expect(110.hz.saw.filter(:lowpass, cutoff: 900, resonance: 0.3, slope: 24.constant.named('slope')).sample(2000)).to eq(lp4)
        expect(saw.filter(:lowpass, cutoff: 900, resonance: 0.3, slope: 12)).to be_a(MB::Sound::Filter::SampleWrapper)
        expect(saw.filter(:lowpass, cutoff: 900, resonance: 0.3, slope: 12.0.constant)).to be_a(MB::Sound::Filter::SampleWrapper)

        expect { saw.filter(:lowpass, cutoff: 900, slope: 18) }.to raise_error(ArgumentError, /12 or 24/)
        expect { saw.filter(:highpass, cutoff: 900, slope: 24) }.to raise_error(ArgumentError, /:lowpass/)
        expect { saw.filter(:lowpass, cutoff: 900, slope: 110.hz.saw) }.to raise_error(ArgumentError, /builds/)
      end

      it 'prints and loads back as filter(:lowpass, ..., slope:)' do
        g = 110.hz.saw.filter(:lowpass, cutoff: 900, resonance: 0.2, slope: 12)
        expect(g.to_ruby).to include('filter(:lowpass, cutoff: 900, resonance: 0.2, slope: 12)')
        expect(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g)).sample(800)).to eq(g.sample(800))
      end
    end

    it 'wraps a Filter::FourPole object at its cutoff and resonance' do
      f = MB::Sound::Filter::FourPole.new(cutoff: 700, resonance: 0.4)
      node = saw.filter(f)
      expect(node).to be_a(MB::Sound::GraphNode::FourPole)
      expect(node.sample(800)).to eq(filtered(700.0, 0.4, 110.hz.saw.sample(800).dup))
    end
  end
end
