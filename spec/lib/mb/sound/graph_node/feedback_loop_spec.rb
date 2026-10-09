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
  def ks(f, compensate: true, damping: nil, sustain: true, quality: 0.5**0.5)
    exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
    exc.feedback(compensate: compensate, sustain: sustain) { |fb, input|
      d = fb.delay((48000.0 / f).samples, smoothing: false)
      lp = (d + d.delay(1.samples)) * 0.4985
      lp = lp.filter(:lowpass, cutoff: f * damping, quality: quality) if damping
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

    # The phase delay at f of the KS loop with a lowpass at damp * f (the
    # two-sample average's half sample plus the SVF's phase delay)
    def ks_phase_delay(f, damp)
      svf = MB::Sound::Filter::SVF.new(:lowpass, 48000, f * damp, quality: 0.5**0.5)
      w = 2 * Math::PI * f / 48000.0
      0.5 - svf.response(w).arg / w
    end

    it "tunes a string with a loop lowpass at the played pitch (within 0.05 cents at 4x and 8x, 0.25 at 2x)" do
      [[220, 8, 0.05], [880, 4, 0.05], [440, 2, 0.25]].each do |f, damp, tol|
        [false, true].each do |sustain|
          l = ks(f, damping: damp, sustain: sustain)
          d = l.sample(96000)[4800...(4800 + 65536)]
          expect(cents(pitch(d, f), f).abs).to be < tol
          expect(l.compensate).to eq(:pitch)
          # (with sustain, the shelf's phase at the pitch is in the latency)
          expect(l.latency).to be_within(1e-9).of(ks_phase_delay(f, damp)) unless sustain
        end
      end
    end

    it "with compensate: :dc uses the group delay at DC (within 3 cents at 4x the pitch)" do
      [[220, 8, 0.5], [880, 4, 3]].each do |f, damp, tol|
        l = ks(f, damping: damp, compensate: :dc)
        d = l.sample(96000)[4800...(4800 + 65536)]
        expect(cents(pitch(d, f), f).abs).to be < tol
        g = Math.tan(Math::PI * f * damp / 48000.0)
        expect(l.latency).to be_within(1e-9).of(0.5 + 1 / (2 * g * 0.5**0.5))
        expect(cents(pitch(ks(f, damping: damp, compensate: false).sample(96000)[4800...(4800 + 65536)], f), f)).to be < -40
      end
    end

    it 'keeps a moving loop lowpass in tune and the same at every block size (ramps every 16 samples)' do
      make = -> {
        exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
        exc.feedback { |fb, input|
          d = fb.delay((48000.0 / 440).samples, smoothing: false)
          input + ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 3.hz.lfo.at(1320..2640), quality: 0.5**0.5)
        }
      }
      a = make.call
      x = Array.new(375) { a.sample(256).to_a }.flatten
      b = make.call
      sizes = [1, 37, 512, 15, 800, 64, 16, 333]
      y = []
      i = 0
      y.concat(b.sample(sizes[(i += 1) % sizes.length]).to_a) while y.length < x.length
      expect(y.first(x.length)).to eq(x)
      expect(b.latency).to be_between(3.0, 8.0)
      # In tune while the cutoff sweeps (the fundamental over 1.4 s)
      expect(cents(pitch(x[4800...(4800 + 65536)], 440), 440).abs).to be < 0.1
    end

    it 'follows a highpass cutoff that changes after holding still (not only lowpasses and allpasses)' do
      exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
      cutoff = 100.constant
      l = exc.feedback(sustain: false) { |fb, input|
        input + fb.delay(440.hz.period, smoothing: false).filter(:highpass, cutoff: cutoff, quality: 0.5**0.5) * 0.9
      }
      3.times { l.sample(512) }
      before = l.latency
      cutoff.constant = 400
      3.times { l.sample(512) }
      expect(l.latency).not_to eq(before)

      ref = exc.feedback(sustain: false) { |fb, input|
        input + fb.delay(440.hz.period, smoothing: false).filter(:highpass, cutoff: 400, quality: 0.5**0.5) * 0.9
      }
      ref.sample(512)
      expect(l.latency).to be_within(1e-9).of(ref.latency)
    end

    it 'rejects an unknown compensation mode' do
      expect { MB::Sound.noise.feedback(compensate: :maybe) { |fb, input| input + fb.delay(10.samples) * 0.5 } }.to raise_error(ArgumentError, /compensate/)
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
      # The phase delay at the echoes' fundamental (100 Hz), within a
      # thousandth of a sample of the group delay at DC (1 / (2 g Q))
      svf = l.program.ops.grep(MB::Sound::Plan::Loop::Op::Svf)[0].filter
      w = 2 * Math::PI / 480
      expect(l.latency).to be_within(1e-9).of(0.5 - svf.response(w).arg / w)
      g = Math.tan(Math::PI * 4000 / 48000.0)
      expect(l.latency).to be_within(1e-3).of(0.5 + 1 / (2 * g * svf.quality))
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

  describe 'sustain' do
    # The amplitude of +f+ Hz in +d+ over 20 periods from sample +start+
    # (mean and trend removed: the loop's slowly decaying DC mode).
    def level(d, f, start)
      n = (20 * 48000.0 / f).round
      x = Numo::DFloat.cast(d[start...(start + n)])
      k = Numo::DFloat.new(n).seq
      x -= x.mean
      kc = k - (n - 1) / 2.0
      x -= kc * ((x * kc).sum / (kc * kc).sum)
      w = 2 * Math::PI * f / 48000
      2 * Math.hypot((x * Numo::NMath.cos(k * w)).sum, (x * Numo::NMath.sin(k * w)).sum) / n
    end

    # T60 in seconds of the fundamental: a line fit to its level in dB
    # every 10 periods from 0.05 s to the end of +d+ (less 20 periods) or
    # until it is 50 dB down
    def t60(d, f)
      step = (10 * 48000.0 / f).round
      pts = (2400...(d.length - 2 * step)).step(step).map { |i| [i / 48000.0, 20 * Math.log10(level(d, f, i))] }
      pts = pts.take_while { |_, y| y > pts[0][1] - 50 }
      mx = pts.sum(&:first) / pts.length
      my = pts.sum(&:last) / pts.length
      slope = pts.sum { |x, y| (x - mx) * (y - my) } / pts.sum { |x, _| (x - mx)**2 }
      -60 / slope
    end

    it 'keeps the fundamental ringing as long as without the loop lowpass (T60 within 2%, 5% at the pitch), from 8x down to the pitch' do
      [110, 440, 1760].each do |f|
        ref = t60(ks(f).sample(48000), f)
        [8, 4, 2, 1].each do |damp|
          l = ks(f, damping: damp)
          d = l.sample(48000)
          expect(t60(d, f)).to be_within(ref * (damp == 1 ? 0.05 : 0.02)).of(ref), "#{f} Hz, lowpass at #{damp}x"
          h = MB::Sound::Filter::SVF.new(:lowpass, 48000, f * damp, quality: 0.5**0.5).response(2 * Math::PI * f / 48000).abs
          # (aimed a little below 1 / h: see Program#sustain_stretch)
          expect(l.sustain_ratio).to be_within(0.01 / h).of(1 / h)
        end
        # Without sustain, a lowpass at 2x the pitch rings a tenth as long
        # (110-440 Hz; a quarter at 1760 Hz, where the average damps too)
        expect(t60(ks(f, damping: 2, sustain: false).sample(48000), f)).to be < ref * (f < 1000 ? 0.12 : 0.3)
      end
    end

    it 'limits the boost (a lowpass at half the pitch rings shorter again, but stays stable)' do
      l = ks(440, damping: 0.5)
      d = l.sample(96000)
      expect(l.sustain_ratio).to be_between(2.0, 2.2)
      expect(d[-4800..].abs.max).to be < 1e-3
      expect(d.to_a.all?(&:finite?)).to eq(true)
    end

    it 'leaves loops without SVF filters and filter types other than gentle lowpasses unboosted' do
      plain = ks(440)
      expect(plain.program.sustain).to be_nil
      expect(plain.sample(4800)).to eq(ks(440, sustain: false).sample(4800))

      exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
      hp = exc.feedback { |fb, input| input + fb.delay(440.hz.period, smoothing: false).filter(:highpass, cutoff: 660, quality: 0.5**0.5) * 0.99 }
      d = hp.sample(96000)
      expect(hp.sustain_ratio).to eq(1.0)
      expect(d[-4800..].abs.max).to be < 1e-3

      resonant = ks(440, damping: 0.8, quality: 1)
      resonant.sample(4800)
      expect(resonant.sustain_ratio).to eq(1.0)
    end

    it 'cuts flat where a filter has gain above 1 at the pitch' do
      l = ks(440, damping: 1, quality: 2)
      l.sample(4800)
      expect(l.sustain_ratio).to be_within(0.005).of(1 / 2.0)
    end

    it 'is off for #delay echo loops and with sustain: false' do
      expect(MB::Sound.noise.delay(0.1, feedback: 0.5) { |fb| fb.filter(:lowpass, cutoff: 3000) }.sustain).to eq(false)
      expect(ks(440, sustain: false).sustain).to eq(false)
      expect(ks(440, damping: 2).sustain).to eq(:pitch)
    end

    it 'rejects an unknown sustain mode' do
      expect { MB::Sound.noise.feedback(sustain: :dc) { |fb, input| input + fb.delay(0.01) * 0.5 } }.to raise_error(ArgumentError, /sustain/)
    end

    it 'keeps a swept cutoff in tune and the same at every block size' do
      make = -> {
        exc = MB::Sound.noise(seed: 1).at(0.5) * MB::Sound.adsr(0, 0.002, 0, 0.002, hold: false)
        exc.feedback { |fb, input|
          d = fb.delay((48000.0 / 440).samples, smoothing: false)
          input + ((d + d.delay(1.samples)) * 0.4985).filter(:lowpass, cutoff: 3.hz.lfo.at(330..1320), quality: 0.5**0.5)
        }
      }
      a = make.call
      x = Array.new(375) { a.sample(256).to_a }.flatten
      b = make.call
      sizes = [1, 37, 512, 15, 800, 64, 16, 333]
      y = []
      i = 0
      y.concat(b.sample(sizes[(i += 1) % sizes.length]).to_a) while y.length < x.length
      expect(y.first(x.length)).to eq(x)
      expect(cents(pitch(x[4800...(4800 + 65536)], 440), 440).abs).to be < 0.1
      # The fundamental still rings after 1.5 s of the cutoff dipping below
      # the pitch (without sustain it is gone, under -180 dB)
      expect(level(x, 440, 74400)).to be > 1e-4
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

  describe '#delay with an insert pipeline (d.fb, d.wet)' do
    def impulse = PlanSpecHelpers::Source.new(kind: :impulses, at: [0])

    # Each echo of an impulse through +l+ at multiples of 480 samples:
    # [sum (DC gain), center of mass relative to the echo time, energy],
    # plus the echo's samples
    def echoes(l, n = 3)
      out = Numo::DFloat.cast(l.sample(480 * (n + 1)))
      idx = Numo::DFloat.new(120).seq - 60
      Array.new(n) { |i|
        w = out[(480 * (i + 1) - 60)...(480 * (i + 1) + 60)]
        { sum: w.sum, center: (w * idx).sum / w.sum, energy: (w**2).sum, data: w }
      }
    end

    it 'with d.fb processes only the repeats (first echo clean)' do
      e = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d| d.fb { |fb| fb * 0.5 } })
      expect(e.map { |x| x[:data][60] }.zip([1.0, 0.4, 0.16]).map { |a, b| (a - b).abs }.max).to be < 1e-6

      e = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d| d.fb { |fb| fb.filter(3000.hz.lowpass) } })
      expect(e[0][:data][60]).to eq(1.0)
      expect(e[0][:energy]).to be_within(1e-9).of(1.0) # clean
      # Each repeat lowpassed once more (DC gain 0.8 per pass, less energy),
      # exactly on time (the loop's delay absorbs the filter's latency)
      expect(e.map { |x| x[:sum] }).to match([be_within(1e-4).of(1), be_within(1e-4).of(0.8), be_within(1e-3).of(0.64)])
      expect(e[1][:energy] / 0.64).to be < 0.25
      expect(e[2][:energy] / e[1][:energy]).to be < 0.8
      expect(e[1][:center]).to be_within(0.01).of(0)
      expect(e[2][:center]).to be_within(0.01).of(0)
    end

    it 'with d.wet processes every echo once, without feeding it back' do
      e = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d| d.wet { |wet| wet.filter(3000.hz.lowpass) } })
      # Every echo has the same (lowpassed) shape, 0.8 times the last
      expect(e[0][:energy]).to be < 0.25
      expect((e[1][:data] - e[0][:data] * 0.8).abs.max).to be < 1e-6
      expect((e[2][:data] - e[1][:data] * 0.8).abs.max).to be < 1e-6
      # The wet chain is outside the loop: its latency isn't compensated
      expect(e[0][:center]).to be > 1
    end

    it 'with both, processes the repeats in the loop and every echo on the way out' do
      both = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d|
        d.fb { |fb| fb.filter(3000.hz.lowpass) }
        d.wet { |wet| wet.filter(5000.hz.lowpass) }
      })
      wet = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d| d.wet { |w| w.filter(5000.hz.lowpass) } })
      expect((both[0][:data] - wet[0][:data]).abs.max).to be < 1e-6 # first echo: only the wet chain
      expect(both[1][:energy]).to be < wet[1][:energy] * 0.75 # repeats darker
      # The same as the d.fb-only echoes through the wet chain afterwards
      ref = impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |d| d.fb { |f| f.filter(3000.hz.lowpass) } }.filter(5000.hz.lowpass)
      after = echoes(ref)
      both.zip(after).each { |a, b| expect((a[:data] - b[:data]).abs.max).to be < 1e-6 }
      expect(both.map { |x| x[:sum] }).to match([be_within(1e-3).of(1), be_within(1e-3).of(0.8), be_within(1e-3).of(0.64)])
    end

    it 'keeps the tape-style block (a returned node) processing every echo' do
      e = echoes(impulse.delay(480.samples, feedback: 0.8, smoothing: false) { |fb| fb * 0.5 })
      expect(e.map { |x| x[:data][60] }.zip([0.5, 0.2, 0.08]).map { |a, b| (a - b).abs }.max).to be < 1e-6
    end

    it 'mixes dry and wet levels around the pipeline' do
      l = impulse.delay(480.samples, feedback: 0.5, smoothing: false, dry: 0.25, wet: 0.5) { |d| d.fb { |fb| fb * 0.5 } }
      out = l.sample(1500).to_a
      expect(out[0]).to eq(0.25)
      expect(out[480]).to be_within(1e-7).of(0.5)
      expect(out[960]).to be_within(1e-7).of(0.5 * 0.25)
    end

    it 'raises without a builder block or with a builder given twice' do
      expect { impulse.delay(48.samples, feedback: 0.5) { |d| d.fb } }.to raise_error(ArgumentError, /d.fb takes a block/)
      expect { impulse.delay(48.samples, feedback: 0.5) { |d| d.wet { |w| w }; d.wet { |w| w } } }.to raise_error(ArgumentError, /only be given once/)
      expect { impulse.delay(48.samples, feedback: 0.5) { |d| d.fb { |f| 3 } } }.to raise_error(ArgumentError, /must return a graph node/)
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
