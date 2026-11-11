RSpec.describe('MB::Sound::GraphNode::Derivative and Integral') do
  include BufferSizeHelpers
  include PlanSpecHelpers

  def input(data) = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(data)])

  def sine(f, amp, n = 9600)
    t = Numo::DFloat.new(n).seq
    Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * f / 48000) * amp)
  end

  describe MB::Sound::GraphNode::Derivative do
    it 'gives the backward difference per second (and per sample), starting at 0' do
      x = [0.5, 0.75, 0.25, 0.25, 1.0]
      expect(input(x).derivative(per: :sample).sample(5).to_a).to eq([0, 0.25, -0.5, 0, 0.75])
      expect(input(x).derivative.sample(5).to_a).to eq([0, 12000, -24000, 0, 36000])
    end

    it 'gives the central difference one sample late with mode: :central' do
      x = [0.0, 1.0, 3.0, 6.0, 10.0]
      expect(input(x).derivative(mode: :central, per: :sample).sample(5).to_a).to eq([0, 0.5, 1.5, 2.5, 3.5])
    end

    it 'measures a sine at 2 pi f per second (backward difference: within 0.01%)' do
      peak = 100.hz.sine.derivative.sample(48000).abs.max
      expect(peak).to be_within(2 * Math::PI * 100 * 1e-4).of(2 * Math::PI * 100)
    end

    it 'stays per second at another sample rate (oversampled)' do
      a = 0.5.hz.lfo.derivative.sample(4800)
      b = 0.5.hz.lfo.derivative.oversample(2).sample(4800)
      # (per sample it would halve; the resampler delays it a little)
      expect((a[100..] - b[100..]).abs.max).to be < 1e-2 * a.abs.max
    end

    it 'matches its Ruby mirror sample for sample (both modes and units, split buffers)' do
      x = sine(1000, 0.89) + sine(3100, 0.1)
      [[0.0, 1.0], [1.0, 0.5], [0.0, 48000.0], [1.0, 24000.0]].each do |settings|
        set = Numo::DFloat.cast(settings)
        sc = Numo::DFloat.zeros(3)
        sr = Numo::DFloat.zeros(3)
        c = []
        rb = []
        [0...800, 800...801, 801...9600].each do |range|
          xx = x[range].dup
          c << MB::Sound::FastControl.derivative(xx, Numo::SFloat.zeros(xx.length), sc, set).dup
          rb << MB::Sound::GraphNode::Derivative.process_ruby(xx, Numo::SFloat.zeros(xx.length), sr, set).dup
        end
        expect(SpecBuffers.join(c)).to eq(SpecBuffers.join(rb)), "settings #{settings}"
        expect(sc).to eq(sr)
      end
    end

    it 'gives the same output at any buffer size' do
      expect_invariant(-> { (110.hz.saw.at(0.9) + 0.3.hz.lfo).derivative(per: :sample) + 3.hz.lfo.slope(mode: :central) * 0.01 }, seconds: 0.5)
    end

    it 'prints and loads as Ruby, aliases under the primary name' do
      g = 110.hz.saw.slope(mode: :central, per: :sample)
      expect(g.to_ruby).to eq('110.hz.saw.derivative(mode: :central, per: :sample)')
      expect(110.hz.saw.differentiate.to_ruby).to eq('110.hz.saw.derivative')
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
      expect(SpecBuffers.join(Array.new(3) { loaded.sample(800).dup })).to eq(SpecBuffers.join(Array.new(3) { g.sample(800).dup }))
    end

    it 'runs per channel on a bundle' do
      b = MB::Sound.stereo(input([0, 1, 3]), input([0, 2, 6])).derivative(per: :sample)
      expect(b.outputs.map { |o| o.sample(3).to_a }).to eq([[0, 1, 2], [0, 2, 4]])
    end

    it 'rejects bad settings and complex input' do
      expect { 1.constant.derivative(mode: :forward) }.to raise_error(ArgumentError, /:backward.*:central/)
      expect { 1.constant.derivative(per: :minute) }.to raise_error(ArgumentError, /per:/)
      expect { 220.hz.saw.hilbert_iir.derivative.sample(10) }.to raise_error(ArgumentError, /real signals/)
    end

    it 'fuses into plans (C and the Ruby mirror, bit for bit)' do
      r = plan_compare(check: :raise) {
        (110.hz.saw.at(0.5) + 0.3.hz.lfo).derivative(per: :sample).filter(:lowpass, cutoff: 2000, quality: 1) +
          3.hz.lfo.at(0.2).derivative(mode: :central) * 0.01
      }
      expect(plan_op_names(r)).to include(:Derivative)
    end
  end

  describe MB::Sound::GraphNode::Integral do
    it 'sums per second (and per sample)' do
      expect(1.constant.integral.sample(48000)[-1]).to eq(1)
      expect(input([1, 2, 3, -4]).integral(per: :sample).sample(4).to_a).to eq([1, 3, 6, 2])
    end

    it 'gives a signal back from its derivative with no leak (less the first sample)' do
      x = sine(3, 1, 4800) + 0.25
      back = input(x).derivative.integral.sample(4800)
      expect((back - (x - x[0])).abs.max).to be < 1e-6
    end

    it 'leaks toward a DC gain of the time constant' do
      out = 1.constant.integral(leak: 0.1).sample(48000)
      expect(out[-1]).to be_within(1e-4).of(0.1)
      # (63% of the way there after one time constant)
      expect(out[4799]).to be_within(1e-3).of(0.1 * (1 - Math.exp(-1)))
      expect(1.constant.integral(leak: 4800.samples).sample(48000)[-1]).to be_within(1e-4).of(0.1)
    end

    it 'holds a true sum forever and flushes a leaking one to zero' do
      x = Numo::SFloat.zeros(48000)
      x[0...10] = 1
      expect(input(x).integral(per: :sample).sample(48000)[-1]).to eq(10)
      expect(input(x).integral(per: :sample, leak: 10.samples).sample(48000)[-1]).to eq(0)
    end

    it 'restarts at rising edges of reset' do
      trig = [0, 1, 1, 0, 0, 1, 0, 0]
      out = input([1] * 8).integral(per: :sample, reset: input(trig)).sample(8).to_a
      expect(out).to eq([1, 1, 2, 3, 4, 1, 2, 3])
    end

    it 'clamps the sum (and its state) to range' do
      x = [1, 1, 1, -1, -1, -1, -1, 1]
      expect(input(x).integral(per: :sample, range: 0..2).sample(8).to_a).to eq([1, 2, 2, 1, 0, 0, 0, 1])
      expect(input(x).integral(per: :sample, range: 0..).sample(8).to_a).to eq([1, 2, 3, 2, 1, 0, 0, 1])
    end

    it 'ends when the input or the reset ends' do
      expect(input([1, 2, 3]).integral.sample(10).length).to eq(3)
      expect(1.constant.integral(reset: input([0, 1, 0])).sample(10).length).to eq(3)
    end

    it 'matches its Ruby mirror sample for sample (leak, clamp, reset, split buffers)' do
      x = sine(1000, 0.89) + sine(3, 0.5)
      trig = sine(20, 1)
      settings = [
        [1.0 / 48000, 1.0, 0, -Float::INFINITY, Float::INFINITY],
        [1.0, Math.exp(-1.0 / 480), 0, -Float::INFINITY, Float::INFINITY],
        [1.0 / 48000, 1.0, 1, -0.001, 0.002],
        [1.0, Math.exp(-1.0 / 4800), 1, 0, Float::INFINITY],
      ]
      settings.product([nil, trig]).each do |s, t|
        set = Numo::DFloat.cast(s)
        sc = Numo::DFloat.zeros(2)
        sr = Numo::DFloat.zeros(2)
        c = []
        rb = []
        [0...800, 800...801, 801...9600].each do |range|
          xx = x[range].dup
          tt = t && t[range].dup
          c << MB::Sound::FastControl.integral(xx, Numo::SFloat.zeros(xx.length), tt, sc, set).dup
          rb << MB::Sound::GraphNode::Integral.process_ruby(xx, Numo::SFloat.zeros(xx.length), tt, sr, set).dup
        end
        expect(SpecBuffers.join(c)).to eq(SpecBuffers.join(rb)), "settings #{s}, reset #{!t.nil?}"
        expect(sc).to eq(sr)
      end
    end

    it 'gives the same output at any buffer size' do
      expect_invariant(-> {
        110.hz.saw.integral(leak: 0.01) * 50 + 0.3.hz.lfo.integrate +
          1.constant.accumulate(reset: 7.hz.lfo.square, range: 0..0.1) + 0.5.hz.lfo.integral(per: :sample) * 1e-4
      }, seconds: 0.5)
    end

    it 'prints and loads as Ruby, aliases under the primary name' do
      g = 110.hz.saw.integrate(leak: 5.ms, reset: 3.hz.lfo.square, range: -1..1, per: :sample)
      expect(g.to_ruby).to eq('110.hz.saw.integral(leak: 5.ms, reset: 3.hz.lfo.square, range: -1..1, per: :sample)')
      expect(1.constant.accumulate.to_ruby).to eq('1.constant.integral')
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
      expect(SpecBuffers.join(Array.new(3) { loaded.sample(800).dup })).to eq(SpecBuffers.join(Array.new(3) { g.sample(800).dup }))
    end

    it 'carries its sum to a rebuilt node (carry: :snapshot)' do
      old = 1.constant.integral
      old.sample(4800)
      fresh = 1.constant.integral
      expect(MB::Sound::NodeTraits.of(fresh).carry).to eq(:snapshot)
      fresh.plan_restore(old.plan_snapshot)
      expect(fresh.sample(1)[0]).to be_within(1e-6).of(0.1 + 1.0 / 48000)
    end

    it 'rejects bad settings and complex input' do
      expect { 1.constant.integral(leak: -1) }.to raise_error(ArgumentError, /negative/)
      expect { 1.constant.integral(leak: 0) }.to raise_error(ArgumentError, /longer than zero/)
      expect { 1.constant.integral(leak: 3.hz.lfo) }.to raise_error(ArgumentError, /fixed time constant/)
      expect { 1.constant.integral(range: 1..0) }.to raise_error(ArgumentError, /low to high/)
      expect { 1.constant.integral(reset: 3) }.to raise_error(ArgumentError, /reset/)
      expect { 1.constant.integral(per: :beat) }.to raise_error(ArgumentError, /per:/)
      expect { 220.hz.saw.hilbert_iir.integral.sample(10) }.to raise_error(ArgumentError, /real signals/)
    end

    it 'fuses into plans with and without a reset (C and the Ruby mirror, bit for bit)' do
      r = plan_compare(check: :raise) {
        110.hz.saw.at(0.5).integral(leak: 0.002).filter(:lowpass, cutoff: 2000, quality: 1) * 100 +
          1.constant.integral(reset: 7.hz.lfo.square, range: 0..0.1)
      }
      expect(plan_op_names(r).count(:Integral)).to eq(2)
    end
  end
end
