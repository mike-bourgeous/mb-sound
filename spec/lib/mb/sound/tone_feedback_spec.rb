RSpec.describe('Tone#feedback (operator self-feedback)') do
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
      'a constant amount' => -> { 125.hz.feedback(1.3) },
      'a large constant amount (chaotic)' => -> { 431.7.hz.feedback(3.5) },
      'a negative amount' => -> { 125.hz.feedback(-1.2) },
      'an amount node' => -> { 211.hz.feedback(3.hz.lfo.at(0..2)) },
      'a gain node (envelope)' => -> {
        125.hz.feedback(1.5, gain: MB::Sound.adsr(0.002, 0.01, 0.4, 0.005, hold: 0.015))
      },
      'gain and amount nodes, #at, FM and PM' => -> {
        200.hz.fm(7.hz.lfo.at(30)).pm(301.hz.at(0.8)).feedback(5.hz.lfo.at(0.3..1.7), gain: 2.hz.lfo.at(0.2..1)).at(0.7..0.1)
      },
      'resets (key sync) and a reset target' => -> {
        t = MB::Sound::Notes.new(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n32.loop).trigger
        170.hz.feedback(1.4).reset(t, to: 1.0)
      },
      'random resets' => -> {
        t = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(2000).tap { |a| a[[5, 130, 131, 600]] = 1 }])
        170.hz.feedback(1.1).reset(t).rnd(seed: 3)
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

  it 'plays a plain sine with feedback 0' do
    a = 123.4.hz.pm(5.hz.at(0.3)).feedback(0).sample(2000)
    b = 123.4.hz.pm(5.hz.at(0.3)).sample(2000)
    expect((a - b).abs.max).to be < 1e-6
  end

  it 'applies the gain inside the loop: feedback 0 with a gain node is the sine times the gain' do
    g = Numo::SFloat.linspace(0, 1, 1000)
    a = 300.hz.feedback(0, gain: input(g)).sample(1000)
    b = 300.hz.sample(1000) * g
    expect((a - b).abs.max).to be < 1e-6
  end

  it 'applies #at outside the loop' do
    a = 125.hz.feedback(1.3).sample(1000).dup
    b = 125.hz.feedback(1.3).at(0.25..0.75).sample(1000)
    expect((b - (a * 0.25 + 0.5)).abs.max).to be < 1e-6
  end

  it 'carries state across buffers' do
    a = 211.hz.feedback(1.7).sample(1000).dup
    b = pieces(211.hz.feedback(1.7), :sample, [3, 500, 497])
    expect(b).to eq(a)
  end

  it 'turns a sine saw-like at about 1.3 rad' do
    h = harmonics(steady(125.hz.feedback(1.3)), 10)
    # A saw is -6.0, -9.5, -12.0, -14.0, -15.6 dB; the feedback sine's
    # first harmonics are a little lower
    expect(h[0]).to be_between(-10, -5)
    expect(h[4]).to be_between(-25, -14)
  end

  it 'adds only weak harmonics at 0.3 rad' do
    h = harmonics(steady(125.hz.feedback(0.3)), 10)
    expect(h[0]).to be_between(-25, -15)
    expect(h[2]).to be < -35
  end

  it 'gets darker as the in-loop gain falls' do
    loud = harmonics(steady(125.hz.feedback(1.3, gain: 1)), 10)
    soft = harmonics(steady(125.hz.feedback(1.3, gain: 0.3)), 10)
    expect(soft[0]).to be < loud[0] - 6
  end

  it 'follows an amount node' do
    a = 125.hz.feedback(MB::Sound::GraphNode::Constant.new(1.3, sample_rate: 48000)).sample(4000)
    b = 125.hz.feedback(1.3).sample(4000)
    expect((a - b).abs.max).to be < 1e-6
  end

  it 'ends when its gain input ends' do
    env = MB::Sound.adsr(0.001, 0.001, 0.5, 0.001, hold: 0.002)
    t = 200.hz.feedback(1, gain: env)
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
    s = 100.hz.feedback(amount, gain: gain).sources
    expect(s.keys).to include(:feedback, :feedback_gain)
    expect(100.hz.feedback(1).sources.keys).not_to include(:feedback, :feedback_gain)
  end

  it 'has a Pitch shortcut and an alias' do
    t = 100.hz.fb(1.2, gain: 0.5)
    expect(t).to be_a(MB::Sound::Tone)
    expect(t.feedback?).to eq(true)
    expect(t.feedback_amount).to eq(1.2)
    expect(t.feedback_gain).to eq(0.5)
    expect(100.hz.sine.feedback?).to eq(false)
    expect(100.hz.feedback(1).feedback(nil).feedback?).to eq(false)
  end

  it 'works in key-synced synth voices' do
    clip = MB::Sound.seq(MB::Sound::C4, MB::Sound::G4).n8
    t = clip.tone.feedback(1.2, gain: clip.amp_env)
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
      expect { 100.hz.ramp.feedback(1) }.to raise_error(ArgumentError, /Only sines/)
      expect { 100.hz.feedback(1).ramp.sample(10) }.to raise_error(ArgumentError, /Only sines/)
    end

    it 'raises with sync, pwm, or noise' do
      expect { 100.hz.feedback(1).sync(ratio: 2).sample(10) }.to raise_error(ArgumentError, /synced/)
      expect { 100.hz.feedback(1).pwm(0.3).sample(10) }.to raise_error(ArgumentError, /warped/)
      expect { 100.hz.feedback(1).noise(0.5).sample(10) }.to raise_error(ArgumentError, /noise/)
    end

    it 'raises for bad values' do
      expect { 100.hz.feedback('x') }.to raise_error(ArgumentError)
      expect { 100.hz.feedback(1, gain: :x) }.to raise_error(ArgumentError)
    end

    it 'is fixed once playing' do
      t = 100.hz.feedback(1)
      t.sample(10)
      expect { t.feedback(2) }.to raise_error(FrozenError)
    end
  end

  describe '.dx7_feedback' do
    it 'doubles per step up to 2pi at 7' do
      expect(MB::Sound::Tone.dx7_feedback(0)).to eq(0)
      expect(MB::Sound::Tone.dx7_feedback(7)).to be_within(1e-12).of(2 * Math::PI)
      expect(MB::Sound::Tone.dx7_feedback(6)).to be_within(1e-12).of(Math::PI)
      expect(MB::Sound::Tone.dx7_feedback(1)).to be_within(1e-12).of(Math::PI / 32)
    end

    it 'rejects settings outside 0..7' do
      expect { MB::Sound::Tone.dx7_feedback(8) }.to raise_error(ArgumentError)
      expect { MB::Sound::Tone.dx7_feedback(-1) }.to raise_error(ArgumentError)
    end
  end

  it 'saves and restores the feedback history in the state' do
    t = 100.hz.feedback(1.5)
    t.sample(333)
    h = t.state.to_h
    expect(h[:feedback].length).to eq(2)
    expect(MB::Sound::Tone::State.new(**h).feedback).to eq(h[:feedback])
  end
end
