RSpec.describe(MB::Sound::GraphNode::FourPole, :check_shared) do
  let(:saw) { 110.hz.ramp }

  def filtered(fc, r, input, **opts)
    f = MB::Sound::Filter::FourPole.new(**opts)
    f.dynamic_process(input, cutoff: fc, resonance: r)
  end

  describe 'GraphNode#lp4' do
    it 'gives the same samples as the filter object' do
      input = 110.hz.ramp.sample(1000).dup
      node = 110.hz.ramp.lp4(800, resonance: 0.6)
      expect(node.sample(1000)).to eq(filtered(800.0, 0.6, input))
    end

    it 'reads cutoff and resonance nodes per sample' do
      cutoff = 3.hz.lfo.at(200..4000)
      res = 2.hz.lfo.at(0..1)
      node = 110.hz.ramp.lp4(cutoff, resonance: res, drive: 2, mode: :bp2)
      expect(node.sources.keys).to eq([:input, :cutoff, :resonance])

      out = node.sample(800)
      input = 110.hz.ramp.sample(800).dup
      fc = 3.hz.lfo.at(200..4000).sample(800).dup
      rr = 2.hz.lfo.at(0..1).sample(800).dup
      expect(out).to eq(filtered(fc, rr, input, drive: 2, mode: :bp2))
    end

    it 'works at audio rate (filter FM)' do
      node = 110.hz.ramp.lp4(220.hz.at(1000) + 1500, resonance: 0.5)
      out = node.sample(4800)
      expect(out.isfinite.all?).to eq(true)
      expect(out.abs.max).to be > 0.1
    end

    it 'takes a Pitch as the cutoff frequency' do
      node = 110.hz.ramp.lp4(800.hz, resonance: 0.3)
      expect(node.cutoff).to eq(800.0)
      expect(node.filter.cutoff).to eq(800.0)
    end

    it 'has aliases four_pole and lowpass4' do
      expect(saw.four_pole(500)).to be_a(MB::Sound::GraphNode::FourPole)
      expect(saw.lowpass4(500).filter.mode).to eq(:lp4)
    end

    it 'passes the options to the filter' do
      f = saw.lp4(500, resonance: 1, self_oscillate: true, mode: :hp2, compensation: 0.1).filter
      expect(f).to be_self_oscillate
      expect(f.drive).to eq(1.0)
      expect(f.mode).to eq(:hp2)
      expect(f.compensation).to eq(0.1)
    end

    it 'does not modify a shared input buffer' do
      src = 110.hz.ramp
      a = src.lp4(500, resonance: 0.5)
      b = src * 1
      x = a.sample(800).dup
      y = b.sample(800).dup
      expect(y).to eq(110.hz.ramp.sample(800))
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
      expect(node.filter.cutoff).to eq(500)
      node.sample(5)
      expect(node.filter.cutoff).to eq(500)
    end

    it 'works per channel on bundles' do
      out = MB::Sound.stereo(110.hz.ramp, 165.hz.ramp).lp4(MB::Sound.channels(500, 900), resonance: 0.5)
      expect(out).to be_a(MB::Sound::GraphNode::Channels)
      expect(out.map { |c| c.filter.cutoff }).to eq([500.0, 900.0])
    end

    it 'follows sample rate changes' do
      node = saw.lp4(1000)
      node.sample_rate = 96000
      expect(node.sample_rate).to eq(96000)
      expect(node.filter.sample_rate).to eq(96000)
      expect(node.at_rate(44100).filter.sample_rate).to eq(44100)
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
      expect(saw.filter(:four_pole, cutoff: 500).filter.mode).to eq(:lp4)
      expect(saw.filter(:hp4, cutoff: 500).filter.mode).to eq(:hp4)
    end

    it 'knows every four-pole mode' do
      expect(MB::Sound::GraphNode::FilterMethods::FOUR_POLE_TYPES - [:four_pole]).to eq(MB::Sound::Filter::FourPole::MODES.keys)
    end

    it 'maps quality for four-pole filters to the same gain at the cutoff' do
      node = saw.filter(:lp4, cutoff: 500, quality: 4)
      expect(node.resonance).to be_within(1e-12).of(Math.log(16) / Math.log(196))
      f = node.filter
      f.resonance = node.resonance
      at_cutoff = f.response(2 * Math::PI * 500 / 48000).abs / f.response(0).abs
      expect(at_cutoff).to be_within(1e-6).of(4)

      lin = saw.lp4(500, quality: 4, resonance_curve: :linear)
      lin.filter.resonance = lin.resonance
      expect(lin.filter.loop_gain).to be_within(1e-9).of(f.loop_gain)

      expect(saw.lp4(500, quality: 0.1).resonance).to eq(0)
      expect(saw.lp4(500, quality: 100).resonance).to eq(1)
      expect { saw.lp4(500, quality: 1, resonance: 1) }.to raise_error(ArgumentError, /not both/)
    end

    it 'takes a quality node such as Notes#quality' do
      v = MB::Sound.seq(MB::Sound::C4.n4).notes
      node = v.hz.saw.lp4(v.cutoff(400), quality: v.quality(4))
      expect(node.resonance.sample(10).to_a.uniq.map { |r| r.round(5) }).to eq([(Math.log(16) / Math.log(196)).round(5)])
      expect(node.sample(800).isfinite.all?).to eq(true)
    end

    it 'rejects gain for four-pole filters and resonance for others' do
      expect { saw.filter(:lp4, cutoff: 500, gain: 4) }.to raise_error(ArgumentError, /gain/)
      expect { saw.filter(:lowpass, cutoff: 500, resonance: 0.5) }.to raise_error(ArgumentError, /resonance/)
      expect { saw.filter(:lp4) }.to raise_error(ArgumentError, /Cutoff/)
    end

    it 'wraps a Filter::FourPole object at its cutoff and resonance' do
      f = MB::Sound::Filter::FourPole.new(cutoff: 700, resonance: 0.4)
      node = saw.filter(f)
      expect(node).to be_a(MB::Sound::GraphNode::FourPole)
      expect(node.sample(800)).to eq(filtered(700.0, 0.4, 110.hz.ramp.sample(800).dup))
    end
  end
end
