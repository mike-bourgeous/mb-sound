# Feedback loop programs (MB::Sound::Plan::Loop, FastLoop): the C loop
# against its Ruby mirror bit for bit, and block-size independence, over
# every op and the loop semantics (history, delays, compensation).
RSpec.describe(MB::Sound::Plan::Loop) do
  let(:src) { PlanSpecHelpers::Source }

  def with_engine(engine)
    old = MB::Sound::Plan.engine
    MB::Sound::Plan.engine = engine
    yield
  ensure
    MB::Sound::Plan.engine = old
  end

  # Renders +total+ samples of the loop made by +build+, in blocks of
  # +sizes+ (repeated), with +engine+.
  def render(build, sizes, total, engine: :c)
    with_engine(engine) do
      node = build.call
      out = []
      i = 0
      while out.length < total
        b = node.sample(sizes[i % sizes.length])
        break if b.nil?

        out.concat(b.to_a)
        i += 1
      end
      out.first(total)
    end
  end

  # A deterministic input that doesn't depend on block sizes.
  def input(seed = 1, scale = 0.4)
    src.new(seed: seed, scale: scale)
  end

  BODIES = {
    'a comb (constant whole-sample delay)' => ->(s) {
      s.input.feedback { |y, x| x + y.delay(37.samples) * 0.7 }
    },
    'a one-pole lowpass built from nodes (one-sample history)' => ->(s) {
      s.input.feedback { |y, x| x + (y - x) * 0.95 }
    },
    'Karplus-Strong (compensated fractional delay, two-sample average)' => ->(s) {
      s.input(2, 0.1).feedback { |y, x|
        d = y.delay(100.37.samples, smoothing: false)
        x + (d + d.delay(1.samples)) * 0.498
      }
    },
    'a tape echo insert (SVF highpass and lowpass, softclip)' => ->(s) {
      s.input.delay(733.samples, feedback: 0.8, smoothing: false) { |fb|
        fb.filter(200.hz.highpass(quality: 0.5)).filter(3000.hz.lowpass(quality: 0.5)).softclip(0, 0.5)
      }
    },
    'a flanger (moving sinc delay, softclip)' => ->(s) {
      s.input.feedback { |y, x| x + (y.delay(3.1.hz.lfo.at(40..400).samples, smoothing: false) * -0.8).softclip(0.85, 0.95) }
    },
    'a short moving delay through the sinc/cubic blend' => ->(s) {
      s.input.feedback { |y, x| x + y.delay(7.hz.lfo.at(2..30).samples, smoothing: false) * 0.6 }
    },
    'cubic and linear delays, a smoothed delay change' => ->(s) {
      s.input.feedback { |y, x|
        a = y.delay(57.3.samples, interpolation: :cubic, smoothing: false)
        b = y.delay(0.5.hz.lfo.square.at(80..120).samples, interpolation: :linear)
        x + a * 0.3 + b * 0.3
      }
    },
    'SVF types with moving cutoff, quality, and gain nodes' => ->(s) {
      s.input.feedback { |y, x|
        d = y.delay(311.samples, smoothing: false)
        lp = d.filter(:lowpass, cutoff: 5.hz.lfo.at(300..4000), quality: 0.3.hz.lfo.at(0.5..4))
        pk = lp.filter(:peak, cutoff: 1200, quality: 2, gain: 2.hz.lfo.at(0.5..2))
        bp = d.filter(:bandpass, cutoff: 700, quality: 3)
        x + (pk + bp * 0.3).softclip * 0.7
      }
    },
    'division, power, and a plain shaper' => ->(s) {
      s.input.feedback { |y, x|
        d = y.delay(64.samples)
        g = 3.constant + 0.2.hz.lfo.at(0..1)
        x + (d / g).aclip(-0.9, 0.9) + (d.abs + 0.5) ** 0.5.constant * 0.01
      }
    },
    'a one-sample history and a delay together' => ->(s) {
      s.input.feedback { |y, x| x + y * 0.3 + y.delay(10.samples) * 0.3 }
    },
    'two delays in series' => ->(s) {
      s.input.feedback { |y, x| x + y.delay(20.samples).delay(31.5.samples).softclip * 0.5 }
    },
    'a gain node on a parallel path (latency per sample)' => ->(s) {
      s.input(3, 0.1).feedback { |y, x|
        d = y.delay(90.25.samples, smoothing: false)
        g = 1.3.hz.lfo.at(0..1)
        x + (d * g + d.delay(1.samples) * (1 - g)) * 0.49
      }
    },
  }.freeze

  BODIES.each do |name, body|
    describe name do
      let(:build) { -> { body.call(self) } }
      let(:total) { 12000 }

      it 'runs in C exactly as its Ruby mirror, at any block sizes' do
        c = render(build, PlanSpecHelpers::SIZES, total)
        r = render(build, PlanSpecHelpers::SIZES.reverse, total, engine: :ruby)
        expect(c.length).to eq(total)
        expect(c.map(&:finite?).all?).to eq(true)
        expect(c).to eq(r)
        expect(c.map(&:abs).max).to be > 0.01
      end

      it 'gives the same samples at every block size' do
        a = render(build, [800], total)
        b = render(build, PlanSpecHelpers::SIZES, total)
        c = render(build, [1, 2, 3], 3000)
        expect(b).to eq(a)
        expect(c).to eq(a.first(3000))
      end

      it 'passes check mode' do
        old = MB::Sound::Plan.check
        MB::Sound::Plan.check = :raise
        expect { render(build, PlanSpecHelpers::SIZES, 4000) }.not_to raise_error
      ensure
        MB::Sound::Plan.check = old
      end
    end
  end

  it 'has the C extension opcodes' do
    c = MB::Sound::FastLoop.constants
    MB::Sound::Plan::Loop::Program::OPCODES.each { |name, num| expect(c[name]).to eq(num), name.to_s }
    expect(c[:sinc_blend]).to eq(MB::Sound::Plan::Loop::Program::SINC_BLEND)
    expect(c[:svf_flush]).to eq(MB::Sound::Plan::Loop::Program::SVF_FLUSH)
    expect(c[:dispatch]).to eq(:goto)
  end

  it 'gives the same samples without multiply-add superinstructions' do
    build = BODIES['a tape echo insert (SVF highpass and lowpass, softclip)']
    a = render(-> { build.call(self) }, [128], 5000)
    old = MB::Sound::Plan::Loop::Program.superinstructions
    MB::Sound::Plan::Loop::Program.superinstructions = false
    b = render(-> { build.call(self) }, [128], 5000)
    expect(b).to eq(a)
  ensure
    MB::Sound::Plan::Loop::Program.superinstructions = old
  end

  it 'lists its program' do
    l = input.delay(733.samples, feedback: 0.8, smoothing: false) { |fb| fb.filter(3000.hz.lowpass).softclip(0, 0.5) }
    s = l.explain
    expect(s).to include('delay_read', 'compensated', 'svf_lowpass', 'softclip', 'loop variable', 'write')
    expect(s).to match(/multiply-add superinstruction/)
  end

  describe 'semantics against plain Ruby' do
    def f32(x) = [x].pack('f').unpack1('f')

    it 'reads the current output through a delay (a comb filter)' do
      x = input.sample(3000).to_a
      out = []
      x.each_with_index do |v, n|
        d = n >= 37 ? out[n - 37] : 0.0
        out << f32(v + f32(f32(0.7) * d))
      end
      expect(render(-> { input.feedback { |y, i| i + y.delay(37.samples) * 0.7 } }, [128], 3000)).to eq(out)
    end

    it 'reads the previous output without a delay (a one-pole lowpass)' do
      x = input.sample(3000).to_a
      out = []
      prev = 0.0
      x.each do |v|
        prev = v + (prev - v) * 0.95
        out << prev
      end
      got = render(-> { input.feedback { |y, i| i + (y - i) * 0.95 } }, [128], 3000)
      expect(got.zip(out).map { |a, b| (a - b).abs }.max).to be < 1e-6
    end
  end

  describe 'short sinc delays' do
    it 'reads cubic below the sinc kernel reach' do
      sinc = render(-> { input.feedback { |y, x| x + y.delay(5.3.samples, smoothing: false) * 0.6 } }, [128], 4000)
      cubic = render(-> { input.feedback { |y, x| x + y.delay(5.3.samples, smoothing: false, interpolation: :cubic) * 0.6 } }, [128], 4000)
      expect(sinc).to eq(cubic)
    end

    it 'reads sinc beyond the kernel reach' do
      sinc = render(-> { input.feedback { |y, x| x + y.delay(30.3.samples, smoothing: false) * 0.6 } }, [128], 4000)
      cubic = render(-> { input.feedback { |y, x| x + y.delay(30.3.samples, smoothing: false, interpolation: :cubic) * 0.6 } }, [128], 4000)
      expect(sinc).not_to eq(cubic)
    end

    it 'reads whole-sample constant delays directly in every mode' do
      %i[sinc cubic linear].map { |m|
        render(-> { input.feedback { |y, x| x + y.delay(7.samples, smoothing: false, interpolation: m) * 0.6 } }, [128], 3000)
      }.each_cons(2) { |a, b| expect(a).to eq(b) }
    end

    it 'blends smoothly through the threshold (no jumps in a sweep)' do
      out = render(-> { 200.hz.sine.at(0.2).feedback { |y, x| x + y.delay(0.25.hz.lfo.ramp.at(30..3).samples, smoothing: false) * 0.3 } }, [128], 96000)
      steps = out.each_cons(2).map { |a, b| (a - b).abs }
      expect(steps.max).to be < 0.1
    end
  end
end
