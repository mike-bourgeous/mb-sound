# Graph feedback (GraphNode#feedback, #delay with a block): latency
# compensation (Karplus-Strong tuning, echo times), the fallback, errors,
# and how loops sit in planned graphs and synths.
RSpec.describe(MB::Sound::GraphNode::FeedbackLoop) do
  # The fundamental of +data+ in Hz: a zero-padded Hann-windowed FFT peak
  # near +guess+, with parabolic interpolation of the log magnitude.
  def pitch(data, guess, rate = 48000.0)
    n = data.length
    w = Numo::DFloat.new(n).seq.map { |i| 0.5 - 0.5 * Math.cos(2 * Math::PI * i / (n - 1)) }
    pad = 1 << 20
    buf = Numo::DFloat.zeros(pad)
    buf[0...n] = Numo::DFloat.cast(data) * w
    mag = Numo::Pocketfft.rfft(buf).abs
    lo = (guess * 0.97 / rate * pad).floor
    hi = (guess * 1.03 / rate * pad).ceil
    i = mag[lo..hi].max_index + lo
    a, b, c = Math.log(mag[i - 1]), Math.log(mag[i]), Math.log(mag[i + 1])
    (i + 0.5 * (a - c) / (a - 2 * b + c)) * rate / pad
  end

  def cents(f, ref) = 1200 * Math.log2(f / ref)

  # A Karplus-Strong string at +f+ Hz: a noise burst into a delay of one
  # period with a two-sample average (half a sample of latency), and an
  # optional lowpass SVF at +damping+ times +f+.
  def ks(f, compensate: true, damping: nil)
    exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
    exc.feedback(compensate: compensate) { |fb, input|
      d = fb.delay((48000.0 / f).samples, smoothing: false)
      lp = (d + d.delay(1.samples)) * 0.4985
      lp = lp.filter(:lowpass, cutoff: f * damping, quality: 0.5**0.5) if damping
      input + lp
    }
  end

  describe 'latency compensation' do
    [110, 440, 1760].each do |f|
      it "tunes a Karplus-Strong string at #{f} Hz within 0.05 cents" do
        l = ks(f)
        d = l.sample(96000)[4800...(4800 + 65536)]
        expect(cents(pitch(d, f), f).abs).to be < 0.05
        expect(l.latency).to eq(0.5)
      end
    end

    it 'leaves an uncompensated string flat by the extra half sample' do
      d = ks(440, compensate: false).sample(96000)[4800...(4800 + 65536)]
      expected = cents(48000.0 / (48000.0 / 440 + 0.5), 440)
      expect(cents(pitch(d, 440), 440)).to be_within(0.05).of(expected)
    end

    it "includes a lowpass SVF's group delay (within 3 cents at 4x the pitch)" do
      [[220, 8, 0.5], [880, 4, 3]].each do |f, damp, tol|
        l = ks(f, damping: damp)
        d = l.sample(96000)[4800...(4800 + 65536)]
        expect(cents(pitch(d, f), f).abs).to be < tol
        g = Math.tan(Math::PI * f * damp / 48000.0)
        expect(l.latency).to be_within(1e-9).of(0.5 + 1 / (2 * g * 0.5**0.5))
        expect(cents(pitch(ks(f, damping: damp, compensate: false).sample(96000)[4800...(4800 + 65536)], f), f)).to be < -40
      end
    end

    it 'keeps tape echoes exactly the delay apart with a saturating, filtered insert' do
      # (0.3: in the shaper's linear range, where latency is defined)
      impulse = PlanSpecHelpers::Source.new(kind: :impulses, at: [0], value: 0.3)
      l = impulse.delay(480.samples, feedback: 0.9, smoothing: false) { |fb| fb.filter(4000.hz.lowpass).softclip(0.5, 1) }
      out = Numo::DFloat.cast(l.sample(2400))
      [480, 960, 1440, 1920].each do |t|
        # The echo's center of mass (its group delay at DC) lands on the
        # delay time (a window wide enough for the filter and sinc tails)
        win = out[(t - 100)...(t + 100)]
        idx = Numo::DFloat.new(200).seq - 100
        center = (win * idx).sum / win.sum
        expect(center).to be_within(0.01).of(0), "echo at #{t}: center #{center}"
      end
      g = Math.tan(Math::PI * 4000 / 48000.0)
      q = l.program.ops.grep(MB::Sound::Plan::Loop::Op::Svf)[0].filter.quality
      expect(l.latency).to be_within(1e-9).of(0.5 + 1 / (2 * g * q))
    end

    it 'counts the one-sample history when a path has no delay' do
      impulse = PlanSpecHelpers::Source.new(kind: :impulses, at: [0])
      l = impulse.feedback { |fb, input| input + fb * 0.3 + fb.delay(10.samples) * 0.3 }
      out = l.sample(40).to_a
      expect(l.latency).to eq(1.0)
      # x at 0, its echo through the delay at 10 (0.3), through the history at 1 (0.3)
      expect(out[0]).to eq(1.0)
      expect(out[1]).to be_within(1e-7).of(0.3)
      expect(out[10]).to be > 0.3
    end
  end

  describe 'fallback' do
    let(:fm_loop) { -> { 220.hz.ramp.at(0.3).feedback { |fb, input| input + 110.hz.pm(fb.delay(2.ms) * 2).at(0.5) } } }

    it 'raises in scripts for a node without loop ops' do
      expect { fm_loop.call }.to raise_error(MB::Sound::Plan::Unsupported, /oscillator.*live mode it runs as a block graph/)
    end

    context 'in live mode' do
      around do |ex|
        old = MB::Sound.live?
        MB::Sound.live = true
        ex.run
      ensure
        MB::Sound.live = old
      end

      it 'warns and runs as a block graph' do
        l = nil
        expect { l = fm_loop.call }.to output(/can't run one sample at a time/).to_stderr
        expect(l.fallback_reason).to match(/oscillator/)
        expect(l.program).to be_nil
        expect(l.explain).to match(/block graph/)
        out = Array.new(20) { l.sample(128).to_a }.flatten
        expect(out.map(&:abs).max).to be > 0.1
        expect(out.all?(&:finite?)).to eq(true)
      end

      it 'runs a loop without a delay one sample at a time (the same samples as the op loop)' do
        l = nil
        expect { l = 220.hz.ramp.at(0.3).feedback { |fb, input| (input + (fb - input) * 0.95).proc { |v| v } } }.to output.to_stderr
        expect(l.instance_variable_get(:@fallback).block).to eq(1)
        MB::Sound.live = false
        ref = 220.hz.ramp.at(0.3).feedback { |fb, input| input + (fb - input) * 0.95 }
        expect(Array.new(10) { l.sample(64).to_a }.flatten).to eq(Array.new(10) { ref.sample(64).to_a }.flatten)
      end

      it 'keeps echo times by reading the delay a block earlier' do
        impulse = -> { PlanSpecHelpers::Source.new(kind: :impulses, at: [0]) }
        l = nil
        expect {
          l = impulse.call.feedback { |fb, input| input + fb.delay(300.samples, smoothing: false).proc { |v| v } * 0.5 }
        }.to output.to_stderr
        expect(l.instance_variable_get(:@fallback).block).to eq(256)
        out = Numo::SFloat.cast(Array.new(10) { l.sample(100).to_a }.flatten)
        expect(out[300]).to eq(0.5)
        expect(out[600]).to eq(0.25)
      end
    end
  end

  describe 'errors' do
    it 'needs a block' do
      expect { 220.hz.sine.feedback }.to raise_error(ArgumentError, /block/)
    end

    it 'points old operator feedback calls to #fm_feedback' do
      expect { 220.hz.sine.feedback(1.2) }.to raise_error(ArgumentError, /fm_feedback/)
      expect { 220.hz.fb(1.2) }.to raise_error(ArgumentError, /fm_feedback/)
    end

    it "needs the block's result to use the loop variable" do
      expect { 220.hz.sine.feedback { |fb, input| input * 0.5 } }.to raise_error(ArgumentError, /doesn't use the loop variable/)
    end

    it 'refuses nodes on the loop that are also read outside it' do
      inner = nil
      expect {
        220.hz.sine.feedback { |fb, input| inner = fb.delay(10.samples) * 0.5; inner.get_sampler; input + inner }
      }.to raise_error(ArgumentError, /also read outside/)
    end

    it 'refuses a delay with its own feedback inside a loop' do
      expect {
        220.hz.sine.feedback { |fb, input| input + fb.delay(10.samples, feedback: 0.5) * 0.5 }
      }.to raise_error(MB::Sound::Plan::Unsupported, /no feedback:/)
    end

    it 'needs feedback: for a delay insert' do
      expect { 220.hz.sine.delay(0.1) { |fb| fb } }.to raise_error(ArgumentError, /feedback:/)
    end
  end

  describe '#delay with a block' do
    it 'is the plain feedback delay with an identity insert (within float32 rounding)' do
      # FastDelay.feedback adds the feedback in double precision; loops
      # round each op to float32
      a = PlanSpecHelpers::Source.new(seed: 4, scale: 0.3).delay(123.samples, feedback: 0.6, smoothing: false) { |fb| fb }
      b = PlanSpecHelpers::Source.new(seed: 4, scale: 0.3).delay(123.samples, feedback: 0.6, smoothing: false)
      x = Array.new(30) { a.sample(100).to_a }.flatten
      y = Array.new(30) { b.sample(100).to_a }.flatten
      expect(x.zip(y).map { |u, v| (u - v).abs }.max).to be < 1e-6
      expect(y.map(&:abs).max).to be > 0.2
    end

    it 'mixes wet and dry, with node levels' do
      dry = PlanSpecHelpers::Source.new(seed: 4, scale: 0.3)
      l = PlanSpecHelpers::Source.new(seed: 4, scale: 0.3).delay(50.samples, feedback: 2.hz.lfo.at(0.2..0.6), dry: 0.5, wet: 1.hz.lfo.at(0..1)) { |fb| fb.softclip }
      out = Array.new(10) { l.sample(100).to_a }.flatten
      # Before the first echo (its sinc read reaches about 12 samples
      # early) the output is the dry level times the input
      d = dry.sample(1000).to_a
      expect(out.first(35).zip(d).map { |a, b| (a - b * 0.5).abs }.max).to be < 1e-6
      expect(out.zip(d).map { |a, b| (a - b * 0.5).abs }.max).to be > 0.01
    end
  end

  describe 'in graphs' do
    it 'lets the plan layer fuse what feeds it, with the same samples as unplanned' do
      old = MB::Sound::Plan.precision
      MB::Sound::Plan.precision = :exact
      build = -> {
        x = 220.hz.sine * 0.5 * 0.3.hz.lfo.at(0.5..1)
        x.feedback { |fb, inp| inp + fb.delay(3.hz.lfo.at(100..200).samples, smoothing: false).softclip * 0.5 } * 0.8
      }
      planned = build.call
      inst = MB::Sound::Plan.install(planned)
      expect(inst).not_to be_nil
      expect(inst.regions.map(&:root)).not_to include(be_a(MB::Sound::GraphNode::FeedbackLoop))
      expect(inst.regions.flat_map(&:members).grep(MB::Sound::GraphNode::Shaper)).to be_empty # the body stays in the loop

      ref = build.call
      a = PlanSpecHelpers::SIZES.flat_map { |n| planned.sample(n).to_a }
      b = PlanSpecHelpers::SIZES.flat_map { |n| ref.sample(n).to_a }
      expect(a).to eq(b)
    ensure
      MB::Sound::Plan.precision = old
    end

    it 'follows a sample rate change (oversampling)' do
      l = MB::Sound.noise(seed: 5).at(0.2).delay(1.ms, feedback: 0.7, smoothing: false) { |fb| fb.filter(:lowpass, cutoff: 2000).softclip }
      o = l.oversample(2)
      expect(l.sample_rate).to eq(96000)
      expect(l.program.rings[0].delay.delay_samples).to eq(96)
      out = Array.new(20) { o.sample(256).to_a }.flatten
      expect(out.all?(&:finite?)).to eq(true)
      expect(out.map(&:abs).max).to be > 0.05
    end

    it 'plays Karplus-Strong voices in a synth, the same at every buffer size' do
      make = -> {
        MB::Sound.synth('spec/test_data/c_major.mid', voices: 4) { |v|
          # (MB::Sound.noise isn't bit-identical across block sizes)
          exc = PlanSpecHelpers::Source.new(seed: 5, scale: 0.5) * v.env(0, 0.004, 0, 0.004)
          exc.feedback { |fb, input| d = fb.delay(v.period, smoothing: false); input + (d + d.delay(1.samples)) * 0.499 } * v.amp_env(0, 1, 1, 0.1)
        }
      }
      a = []
      s = make.call
      200.times { b = s.sample(128); break unless b; a.concat(b.to_a) }
      b = []
      s = make.call
      sizes = [512, 37, 800, 1, 128]
      i = 0
      while b.length < a.length
        x = s.sample(sizes[i % sizes.length])
        break unless x
        b.concat(x.to_a)
        i += 1
      end
      expect(a.map(&:abs).max).to be > 0.01
      expect(b.first(a.length)).to eq(a)
    end
  end
end
