RSpec.describe('Tone#fm_feedback (operator self-feedback)') do
  let(:rate) { 48000 }

  # Samples +tone+ in pieces of the given +lengths+ with +method+
  # (:sample_c or :sample_ruby), returning every sample.
  def pieces(tone, method, lengths)
    out = lengths.map { |n| tone.public_send(method, n)&.dup }.compact
    Numo::SFloat.zeros(0).concatenate(*out)
  end

  def input(data)
    MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(data)])
  end

  # Harmonic levels (dB relative to the fundamental) of a full-cycle
  # buffer +buf+ holding +cycles+ cycles: [H2, H3, ...].
  def harmonics(buf, cycles, count = 6)
    spec = MB::Sound.real_fft(Numo::DFloat.cast(buf)).abs
    h1 = spec[cycles]
    (2..count).map { |h| 20 * Math.log10(spec[cycles * h] / h1) }
  end

  # 125 Hz at 48 kHz: 384 samples per cycle, so 4800 samples hold 12.5
  # cycles; 3840 samples hold exactly 10.
  def steady(tone, settle: 4800, length: 3840)
    tone.sample(settle)
    tone.sample(length).dup
  end

  describe 'C kernel and Ruby mirror' do
    let(:lengths) { [1, 127, 128, 300, 513, 64] }

    {
      'a constant amount' => -> { 125.hz.fm_feedback(1.3.radians) },
      'a large constant amount (chaotic)' => -> { 431.7.hz.fm_feedback(3.5.radians) },
      'a negative amount' => -> { 125.hz.fm_feedback(-1.2.radians) },
      'an amount node' => -> { 211.hz.fm_feedback(3.hz.lfo.at(0..2).radians) },
      'a gain node (envelope)' => -> {
        125.hz.fm_feedback(1.5.radians, gain: MB::Sound.adsr(0.002, 0.01, 0.4, 0.005, hold: 0.015))
      },
      'gain and amount nodes, #at, FM and PM' => -> {
        200.hz.fm(7.hz.lfo.at(30)).pm(301.hz.at(0.8)).fm_feedback(5.hz.lfo.at(0.3..1.7).radians, gain: 2.hz.lfo.at(0.2..1)).at(0.7..0.1)
      },
      'resets (key sync) and a reset target' => -> {
        t = MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n32.loop).trigger
        170.hz.fm_feedback(1.4.radians).reset(t, to: 1.0.radians)
      },
      'DC kept (dc: true)' => -> { 211.hz.fm(3.hz.lfo.at(40)).fm_feedback(2.2.radians, dc: true) },
      'an LFO-rate feedback sine with DC removal' => -> { 3.hz.fm_feedback(1.5.radians).at(0.2..0.8) },
      'cycles and a node gain' => -> { 150.hz.fm_feedback_cycles(2.hz.lfo.at(0..0.3), gain: 5.hz.lfo.at(0.5..1)) },
      'resets keeping the feedback history' => -> {
        t = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(2000).tap { |a| a[[7, 300, 301, 900]] = 1 }])
        170.hz.fm_feedback(1.9.radians).reset(t, keep_feedback: true)
      },
      'random resets' => -> {
        t = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(2000).tap { |a| a[[5, 130, 131, 600]] = 1 }])
        170.hz.fm_feedback(1.1.radians).reset(t).rnd(seed: 3)
      },
    }.each do |name, make|
      it "gives the same samples with #{name}" do
        MB::Sound.seed(1)
        a = make.call
        c = pieces(a, :sample_c, lengths)
        MB::Sound.seed(1)
        b = make.call
        r = pieces(b, :sample_ruby, lengths)
        expect(c.length).to eq(r.length)
        expect(c).to eq(r)
        expect(a.state.feedback).to eq(b.state.feedback)
        expect(a.state.phi).to eq(b.state.phi)
        expect(c.abs.max).to be > 0.05
      end
    end
  end

  it 'plays a plain sine with feedback 0 and dc: true' do
    a = 123.4.hz.pm(5.hz.at(0.3)).fm_feedback(0, dc: true).sample(2000)
    b = 123.4.hz.pm(5.hz.at(0.3)).sample(2000)
    expect((a - b).abs.max).to be < 1e-6
  end

  it 'applies the gain inside the loop: feedback 0 with a gain node is the sine times the gain' do
    g = Numo::SFloat.linspace(0, 1, 1000)
    a = 300.hz.fm_feedback(0, gain: input(g), dc: true).sample(1000)
    b = 300.hz.sample(1000) * g
    expect((a - b).abs.max).to be < 1e-6
  end

  describe 'DC offset' do
    def mean_after(tone, settle = 48000)
      tone.sample(settle)
      tone.sample(48000).mean
    end

    it 'is removed by default at audio and LFO rates' do
      expect(mean_after(110.hz.fm_feedback(2.0.radians)).abs).to be < 1e-3
      expect(mean_after(440.hz.fm_feedback(3.0.radians)).abs).to be < 1e-3
      expect(mean_after(2.hz.fm_feedback(1.5.radians), 480000).abs).to be < 1e-3
    end

    it 'is kept with dc: true' do
      expect(mean_after(110.hz.fm_feedback(2.0.radians, dc: true))).to be_within(0.02).of(-0.25)
    end

    it 'barely changes the harmonics (a one-pole highpass at 1/20 of the frequency)' do
      a = harmonics(steady(125.hz.fm_feedback(1.5.radians)), 10)
      b = harmonics(steady(125.hz.fm_feedback(1.5.radians, dc: true)), 10)
      expect(a.zip(b).map { |x, y| (x - y).abs }.max).to be < 0.05
    end

    it 'is removed from the output only: the loop and the in-loop gain are unchanged' do
      a = 200.hz.fm_feedback(1.8.radians)
      b = 200.hz.fm_feedback(1.8.radians, dc: true)
      a.sample(1000)
      b.sample(1000)
      expect(a.state.feedback[0..1]).to eq(b.state.feedback[0..1])
    end
  end

  describe 'resets' do
    def trig(*at)
      MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4000).tap { |a| a[at] = 1 }])
    end

    it 'clear the feedback history, so every note starts identically' do
      t = 170.hz.fm_feedback(1.9.radians).reset(trig(1000, 2500))
      x = t.sample(4000)
      expect(x[2500...3000]).to eq(x[1000...1500])
    end

    it 'start like a fresh tone' do
      fresh = 170.hz.fm_feedback(1.9.radians).sample(400).dup
      t = 170.hz.fm_feedback(1.9.radians).reset(trig(1000))
      expect(t.sample(4000)[1000...1400]).to eq(fresh)
    end

    it 'keep the history with keep_feedback: true or #keep_feedback' do
      a = 170.hz.fm_feedback(1.9.radians).reset(trig(1000, 2500), keep_feedback: true).sample(4000).dup
      expect(a[2500...3000]).not_to eq(a[1000...1500])
      b = 170.hz.fm_feedback(1.9.radians).keep_feedback.reset(trig(1000, 2500)).sample(4000)
      expect(b).to eq(a)
      expect(170.hz.fm_feedback(1.radians).keep_feedback.keep_feedback?).to eq(true)
      expect(170.hz.fm_feedback(1.radians).keep_feedback?).to eq(false)
    end

    it 'clear on key sync in synth voices unless kept' do
      clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::C4).n8
      render = ->(keep) {
        t = clip.tone.fm_feedback(1.9.radians)
        t.keep_feedback if keep
        out = []
        while (b = t.sample(500))
          out << b.dup
          break if out.length > 30
        end
        Numo::SFloat.zeros(0).concatenate(*out)
      }
      n8 = (60.0 / 120 / 2 * 48000).round
      x = render.call(false)
      expect(x[n8...(n8 + 500)]).to eq(x[0...500])
      y = render.call(true)
      expect(y[n8...(n8 + 500)]).not_to eq(y[0...500])
    end
  end

  it 'takes the amount in cycles (also as #fm_feedback_cycles), or a radians Phase' do
    a = 125.hz.fm_feedback_cycles(0.25).sample(2000).dup
    b = 125.hz.fm_feedback(0.25).sample(2000).dup
    c = 125.hz.fm_feedback((0.5 * Math::PI).radians).sample(2000).dup
    expect(a).to eq(b)
    expect(c).to eq(b)
    expect(100.hz.fm_fb_cycles(0.1).fm_feedback_amount).to eq(0.1)
    expect(100.hz.fmfb_cycles(0.1).fm_feedback_amount).to eq(0.1)
    expect(100.hz.sine.fmfb_cycles(0.1).fm_feedback_amount).to eq(0.1)
    expect(100.hz.fm_feedback(1.5.radians).fm_feedback_amount).to be_within(1e-15).of(1.5 / (2 * Math::PI))
  end

  it 'has FEEDBACK_MAX = 1 cycle (2pi), the DX7 FB 7 value' do
    expect(MB::Sound::Tone::FEEDBACK_MAX).to eq(1.0)
    expect(MB::Sound::Tone.dx7_feedback(7)).to eq(MB::Sound::Tone::FEEDBACK_MAX)
  end

  it 'applies #at outside the loop' do
    a = 125.hz.fm_feedback(1.3.radians).sample(1000).dup
    b = 125.hz.fm_feedback(1.3.radians).at(0.25..0.75).sample(1000)
    expect((b - (a * 0.25 + 0.5)).abs.max).to be < 1e-6
  end

  it 'carries state across buffers' do
    a = 211.hz.fm_feedback(1.7.radians).sample(1000).dup
    b = pieces(211.hz.fm_feedback(1.7.radians), :sample, [3, 500, 497])
    expect(b).to eq(a)
  end

  it 'turns a sine saw-like at about 1.3 rad' do
    h = harmonics(steady(125.hz.fm_feedback(1.3.radians)), 10)
    # A saw is -6.0, -9.5, -12.0, -14.0, -15.6 dB; the feedback sine's
    # first harmonics are a little lower
    expect(h[0]).to be_between(-10, -5)
    expect(h[4]).to be_between(-25, -14)
  end

  it 'adds only weak harmonics at 0.3 rad' do
    h = harmonics(steady(125.hz.fm_feedback(0.3.radians)), 10)
    expect(h[0]).to be_between(-25, -15)
    expect(h[2]).to be < -35
  end

  it 'gets darker as the in-loop gain falls' do
    loud = harmonics(steady(125.hz.fm_feedback(1.3.radians, gain: 1)), 10)
    soft = harmonics(steady(125.hz.fm_feedback(1.3.radians, gain: 0.3)), 10)
    expect(soft[0]).to be < loud[0] - 6
  end

  it 'follows an amount node' do
    a = 125.hz.fm_feedback(MB::Sound::GraphNode::Constant.new(1.3, sample_rate: 48000).radians).sample(4000)
    b = 125.hz.fm_feedback(1.3.radians).sample(4000)
    expect((a - b).abs.max).to be < 1e-6
  end

  it 'ends when its gain input ends' do
    env = MB::Sound.adsr(0.001, 0.001, 0.5, 0.001, hold: 0.002)
    t = 200.hz.fm_feedback(1.radians, gain: env)
    n = 0
    while (buf = t.sample(100))
      n += buf.length
      break if n > 48000
    end
    expect(n).to be < 1000
  end

  it 'lists node inputs in #sources' do
    amount = 2.hz.lfo
    gain = MB::Sound.adsr(0.1, 0.1, 0.5, 0.1)
    s = 100.hz.fm_feedback(amount, gain: gain).sources
    expect(s.keys).to include(:feedback, :feedback_gain)
    expect(100.hz.fm_feedback(1).sources.keys).not_to include(:feedback, :feedback_gain)
  end

  it 'has Pitch shortcuts and the aliases fmfb and fm_fb' do
    expect(100.hz.fmfb(0.7).fm_feedback_amount).to eq(0.7)
    expect(100.hz.sine.fmfb(0.7).fm_feedback_amount).to eq(0.7)
    expect(100.hz.sine.fm_fb(0.7).fm_feedback_amount).to eq(0.7)

    t = 100.hz.fm_fb(1.2, gain: 0.5)
    expect(t).to be_a(MB::Sound::Tone)
    expect(t.fm_feedback?).to eq(true)
    expect(t.fm_feedback_amount).to eq(1.2)
    expect(t.fm_feedback_gain).to eq(0.5)
    expect(100.hz.sine.fm_feedback?).to eq(false)
    expect(100.hz.fm_feedback(1).fm_feedback(nil).fm_feedback?).to eq(false)
  end

  it 'works in key-synced synth voices' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::G4).n8
    t = clip.tone.fm_feedback(1.2.radians, gain: clip.amp_env)
    expect(t).to be_a(MB::Sound::Notes::KeyedTone)
    out = []
    while (b = t.sample(512))
      out << b.dup
      break if out.length > 200
    end
    out = Numo::SFloat.zeros(0).concatenate(*out)
    expect(out.abs.max).to be_between(0.5, 1.0)
  end

  describe 'unsupported settings' do
    it 'raises for other shapes' do
      expect { 100.hz.ramp.fm_feedback(1) }.to raise_error(ArgumentError, /Only sines/)
      expect { 100.hz.fm_feedback(1).ramp.sample(10) }.to raise_error(ArgumentError, /Only sines/)
    end

    it 'raises with sync, pwm, or noise' do
      expect { 100.hz.fm_feedback(1).sync(ratio: 2).sample(10) }.to raise_error(ArgumentError, /synced/)
      expect { 100.hz.fm_feedback(1).pwm(0.3).sample(10) }.to raise_error(ArgumentError, /warped/)
      expect { 100.hz.fm_feedback(1).noise(0.5).sample(10) }.to raise_error(ArgumentError, /noise/)
    end

    it 'raises for bad values' do
      expect { 100.hz.fm_feedback('x') }.to raise_error(ArgumentError)
      expect { 100.hz.fm_feedback(1, gain: :x) }.to raise_error(ArgumentError)
    end

    it 'is fixed once playing' do
      t = 100.hz.fm_feedback(1)
      t.sample(10)
      expect { t.fm_feedback(2) }.to raise_error(FrozenError)
    end
  end

  describe '.dx7_feedback' do
    it 'doubles per step up to 1 cycle (2pi) at 7' do
      expect(MB::Sound::Tone.dx7_feedback(0)).to eq(0)
      expect(MB::Sound::Tone.dx7_feedback(7)).to eq(1)
      expect(MB::Sound::Tone.dx7_feedback(6)).to eq(0.5)
      expect(MB::Sound::Tone.dx7_feedback(1)).to eq(1.0 / 64)
    end

    it 'rejects settings outside 0..7' do
      expect { MB::Sound::Tone.dx7_feedback(8) }.to raise_error(ArgumentError)
      expect { MB::Sound::Tone.dx7_feedback(-1) }.to raise_error(ArgumentError)
    end
  end

  it 'saves and restores the feedback history in the state' do
    t = 100.hz.fm_feedback(1.5.radians)
    t.sample(333)
    h = t.state.to_h
    expect(h[:feedback].length).to eq(3)
    expect(MB::Sound::Tone::State.new(**h).feedback).to eq(h[:feedback])
  end
end
