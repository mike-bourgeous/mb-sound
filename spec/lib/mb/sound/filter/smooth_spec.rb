RSpec.describe(MB::Sound::Filter::Smooth) do
  def arr(data) = MB::Sound::ArrayInput.new(data: [data])
  def trig(count, *indices) = Numo::SFloat.zeros(count).tap { |t| indices.each { |i| t[i] = 1 } }
  def blocks(node, sizes) = SpecBuffers.join(sizes.map { |n| node.sample(n).dup })

  it 'is what GraphNode#smooth builds' do
    f = 120.hz.square.smooth(60.samples)
    expect(f).to be_a(MB::Sound::Filter::SampleWrapper)
    expect(f.base_filter).to be_a(MB::Sound::Filter::Smooth)
    expect(f.base_filter.smoother).to be_a(MB::Sound::Notes::Smoother)
  end

  describe 'without a curve' do
    let(:step) { Numo::SFloat.zeros(400).tap { |d| d[100..] = 1 } }

    it 'starts on the first input value' do
      out = arr(Numo::SFloat.zeros(10).fill(60)).smooth(0.1).sample(10)
      expect(out.to_a.uniq).to eq([60.0])
    end

    it 'starts on from: and glides to the input' do
      out = arr(Numo::SFloat.zeros(100).fill(1)).smooth(50.samples, from: 0).sample(100)
      expect(out[0]).to be < 0.01
      expect(out[24]).to be_within(0.05).of(0.5)
      expect(out[48..].to_a.uniq).to eq([1.0])
    end

    it 'turns a step into an S-curve of the length, reaching the input exactly' do
      out = arr(step).smooth(100.samples).sample(400)
      expect(out[0...100].to_a.uniq).to eq([0.0])
      expect(out[149]).to be_within(0.02).of(0.5)
      expect(out[199..].to_a.uniq).to eq([1.0])

      # Continuous slope: no slope changes bigger than a quadratic B-spline's
      d = out.diff
      expect(d.diff.abs.max).to be < 4.5 / 100**2
    end

    it 'passes a moving signal, delayed by half the length' do
      lfo = Numo::SFloat.new(48000).seq.map { |i| Math.sin(2 * Math::PI * 3 * i / 48000) }
      out = arr(lfo).smooth(0.01).sample(48000)
      expect(out[24000..].abs.max).to be_within(0.002).of(1)
      expect((out[24240...47000] - lfo[24000...46760]).abs.max).to be < 0.002
    end

    it 'interpolates a stream of 7-bit steps' do
      knob = Numo::SFloat.new(24000).seq.map { |i| (i / 24000.0 * 127).floor / 127.0 }
      out = arr(knob).smooth(0.05).sample(24000)
      # Delayed by half the kernel and half a step
      lag = 1200 + (24000 / 127.0 / 2).round
      ideal = Numo::SFloat.new(24000).seq / 24000.0
      expect((out[6000...18000] - ideal[(6000 - lag)...(18000 - lag)]).abs.max).to be < 0.05 / 127
    end

    it 'smooths adaptively with a Range length' do
      expect(arr(step).smooth(5.ms..50.ms).base_filter.smoother).to be_adaptive
    end
  end

  describe 'with a curve' do
    it 'follows the curve on a single step' do
      out = arr(Numo::SFloat.zeros(300).tap { |d| d[10..] = 2 }).smooth(100.samples, curve: :elastic).sample(300)
      c = MB::Sound::Curve[:elastic]
      t = (Numo::DFloat.new(100).seq + 1) / 100.0
      expect((out[10...110] - c.map(t) * 2).abs.max).to be < 1e-6
      expect(out[110..].to_a.uniq).to eq([2.0])
    end

    it 'adds up overlapping steps' do
      a = Numo::SFloat.zeros(300).tap { |d| d[10..] = 1 }
      b = Numo::SFloat.zeros(300).tap { |d| d[40..] = 0.5 }
      both = arr(a + b).smooth(60.samples, curve: :back).sample(300)
      sum = arr(a).smooth(60.samples, curve: :back).sample(300) + arr(b).smooth(60.samples, curve: :back).sample(300)
      expect((both - sum).abs.max).to be < 1e-6
    end

    it 'keeps the curve kernel bounded on a moving signal, the same at any buffer size' do
      lfo = Numo::SFloat.new(30000).seq.map { |i| Math.sin(2 * Math::PI * 3 * i / 48000) }
      s = arr(lfo).smooth(0.1, curve: :elastic)
      out = s.sample(30000)
      expect(s.base_filter.smoother.plan_arrays[0][4]).to eq((4800 / 64.0).ceil)
      expect(out[20000..].abs.max).to be_within(0.2).of(1)

      other = blocks(arr(lfo).smooth(0.1, curve: :elastic), [1, 7, 800, 367] * 25 + [30000 - 1175 * 25])
      expect(other).to eq(out)
    end

    it 'matches the C kernel with its Ruby mirror' do
      x = Numo::SFloat.new(3000).rand(-1, 1).tap { |v| v[1000..] = 0.25 }
      x[0...1000] = (x[0...1000] * 4).round / 4
      [10, 64, 700].each do |n|
        s1 = MB::Sound::Notes::Smoother.new(n.samples, sample_rate: 48000, curve: :bounce)
        s2 = MB::Sound::Notes::Smoother.new(n.samples, sample_rate: 48000, curve: :bounce)
        s1.plan_start(0.0)
        s2.plan_start(0.0)
        a = Numo::SFloat.zeros(3000)
        b = Numo::SFloat.zeros(3000)
        st1, r1, t1 = s1.plan_arrays
        st2, r2, t2 = s2.plan_arrays
        [0, 1, 900, 1999, 3000].each_cons(2) do |from, to|
          MB::Sound::FastControl.curve(x, a, from, to, st1, r1, t1)
          MB::Sound::Notes::Smoother.curve_ruby(x, b, from, to, st2, r2, t2)
        end
        expect(a).to eq(b)
        expect(st1.to_a).to eq(st2.to_a)
        expect(r1.to_a).to eq(r2.to_a)
      end
    end

    it 'checks the curve kernel arguments' do
      s = MB::Sound::Notes::Smoother.new(10.samples, sample_rate: 48000, curve: :linear)
      s.plan_start(0.0)
      st, r1, t = s.plan_arrays
      x = Numo::SFloat.zeros(10)
      expect { MB::Sound::FastControl.curve(x, Numo::SFloat.zeros(9), 0, 9, st, r1, t) }.to raise_error(ArgumentError, /as many/)
      expect { MB::Sound::FastControl.curve(x, Numo::SFloat.zeros(10), 0, 11, st, r1, t) }.to raise_error(RangeError)
      expect { MB::Sound::FastControl.curve(x, Numo::SFloat.zeros(10), 0, 9, st, r1, t[0...5]) }.to raise_error(ArgumentError, /table/)
      expect { MB::Sound::FastControl.curve(x, Numo::SFloat.zeros(10), 0, 9, st[0...8], r1, t) }.to raise_error(ArgumentError, /9 values/)
    end

    it 'needs a plain length' do
      expect { 1.constant.smooth(5.ms..50.ms, curve: :elastic) }.to raise_error(ArgumentError, /length/)
    end
  end

  describe 'with reset:' do
    let(:data) { Numo::SFloat.zeros(400).tap { |d| d[0...100] = 1; d[100...200] = 2; d[200..] = 3 } }

    it 'jumps to the input on a reset and glides otherwise' do
      out = arr(data).smooth(50.samples, reset: arr(trig(400, 0, 200))).sample(400)

      expect(out[0]).to eq(1)
      expect(out[101]).to be > 1
      expect(out[101]).to be < 1.1
      expect(out[149]).to be_within(1e-6).of(2)
      expect(out[199]).to eq(2)
      expect(out[200]).to eq(3)
    end

    it 'stops a glide in progress' do
      out = arr(data).smooth(200.samples, reset: arr(trig(400, 150))).sample(400)
      expect(out[149]).to be < 2
      expect(out[150]).to eq(2)
      expect(out[200]).to be < 2.01
    end

    it 'stops a curve glide in progress' do
      out = arr(data).smooth(200.samples, curve: :elastic, reset: arr(trig(400, 150))).sample(400)
      expect(out[140]).to be > 2.1
      expect(out[150...200].to_a.uniq).to eq([2.0])
    end

    it 'matches plain #smooth without resets' do
      a = arr(data).smooth(30.samples, reset: arr(trig(400))).sample(400)
      b = arr(data).smooth(30.samples).sample(400)
      expect(a).to eq(b)
    end

    it 'rejects a non-node reset' do
      expect { arr(data).smooth(0.1, reset: 1) }.to raise_error(ArgumentError)
    end
  end

  describe 'in plans' do
    include PlanSpecHelpers

    it 'fuses smoothing (Op::Smooth), with and without curves and resets' do
      [
        ->(c) { (c.sig * 3).smooth(0.004) * 2 },
        ->(c) { (c.sig * 3).smooth(0.004, curve: :elastic) + 1 },
        ->(c) { (c.sig * 3).smooth(300.samples, curve: :back, from: 1) + 1 },
        ->(c) { c.sig.smooth(0.003, reset: 5.hz.lfo.asquare) * 2 },
        ->(c) { c.sig.smooth(0.003, curve: :bounce, reset: 7.hz.lfo.asquare) * 2 },
        ->(c) { c.sig.smooth(1.ms..20.ms) * 2 },
      ].each do |build|
        r = plan_compare(check: :raise) { build.call(Struct.new(:sig).new(PlanSpecHelpers::Source.new(kind: :steps, seed: 3, every: 37))) }
        expect(r.program.ops.map { |op| op.class.name.split('::').last.to_sym }).to include(:Smooth)
      end
    end
  end
end
