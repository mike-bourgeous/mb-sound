RSpec.describe('Tone#gain (output gain inside the oscillator)') do
  def env
    MB::Sound.adsr(0.01, 0.05, 0.5, 0.02, hold: 0.08)
  end

  def collect(node, lengths = [128, 300, 1, 511, 800, 1024, 2000])
    out = []
    lengths.each do |n|
      b = node.sample(n)
      break unless b
      out << b.dup
    end
    out.first.class.zeros(0).concatenate(*out)
  end

  {
    'a sine' => -> { 220.hz.sine },
    'a band-limited ramp with #at' => -> { 220.hz.saw.at(0.3) },
    'a ramp with an offset range' => -> { 110.hz.saw.at(0.2..0.9) },
    'a pulse with pwm' => -> { 330.hz.pwm(0.3).square },
    'a complex sine' => -> { 220.hz.complex_sine },
    'a complex ramp (BLIT)' => -> { 220.hz.complex_saw },
    'a synced square' => -> { 150.hz.square.sync(ratio: 2.3) },
    'a feedback sine' => -> { 220.hz.fm_feedback(1.5) },
    'a wavetable' => -> { 220.hz.wavetable(:saw, scan: 0.5) },
    'a tone with resets and FM' => -> {
      t = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(6000).tap { |a| a[[50, 700, 3000]] = 1 }])
      200.hz.saw.fm(5.hz.lfo.at(20)).reset(t)
    },
  }.each do |name, make|
    it "equals tone * gain bit for bit for #{name}, and C equals Ruby" do
      a = collect(make.call.gain(env))
      b = collect(make.call * env)
      expect(a.length).to be_between(4000, 6000)
      expect(a).to eq(b)

      c = make.call.gain(env)
      r = []
      [300, 1, 511].each { |n| r << sample_with(:ruby, c, n).dup }
      d = make.call.gain(env)
      e = [300, 1, 511].map { |n| d.sample(n).dup }
      # (the naive complex sine's Ruby mirror differs by ~1e-16 already)
      if name == 'a complex sine'
        expect(r.zip(e).map { |x, y| (x - y).abs.max }.max).to be < 1e-6
      else
        expect(r).to eq(e)
      end
    end
  end

  it 'equals tone * number for a constant gain' do
    expect(collect(220.hz.saw.gain(0.3), [1000])).to eq(collect(220.hz.saw * 0.3, [1000]))
    expect(collect(220.hz.saw.amp(-2), [1000])).to eq(collect(220.hz.saw * -2, [1000]))
  end

  it 'leaves the output unchanged without a gain (and with gain(nil))' do
    expect(collect(220.hz.saw.gain(0.5).gain(nil), [1000])).to eq(collect(220.hz.saw, [1000]))
  end

  it 'ends the tone when the gain ends' do
    t = 220.hz.gain(env)
    n = 0
    while (b = t.sample(100))
      n += b.length
      break if n > 48000
    end
    expect(n).to be < 6000
  end

  it 'composes with a feedback in-loop gain' do
    a = collect(220.hz.fm_feedback(1.5, gain: 0.5).gain(env), [2000])
    b = collect(220.hz.fm_feedback(1.5, gain: 0.5) * env, [2000])
    expect(a).to eq(b)
  end

  it 'lists a node gain in #sources and has accessors' do
    e = env
    t = 100.hz.gain(e)
    expect(t.sources.keys).to include(:gain)
    expect(100.hz.gain(0.5).output_gain).to eq(0.5)
    expect(100.hz.gain(0.5).sources.keys).not_to include(:gain)
  end

  describe '#at with a node' do
    it 'sets the output gain, the same samples as tone * node, and returns the tone' do
      t = 220.hz.saw.at(0.3)
      expect(t.at(env)).to equal(t)
      expect(t.output_gain).to be_a(MB::Sound::GraphNode)
      expect(collect(220.hz.saw.at(0.3).at(env))).to eq(collect(220.hz.saw.at(0.3) * env))
      expect(collect(220.hz.at(env))).to eq(collect(220.hz.sine * env))
    end

    # Relative difference from the reference, at most about one float32 ulp
    def ulps(a, b)
      (a - b).abs.max / b.abs.max
    end

    it 'merges with a numeric gain into one gain input, within float32 rounding of tone.gain(g) * node' do
      a = 220.hz.saw.gain(0.5).at(env)
      expect(a).to be_a(MB::Sound::Tone)
      expect(a.output_gain).to be_a(MB::Sound::GraphNode)
      x = collect(a)
      y = collect(220.hz.saw.gain(0.5) * env)
      expect(x.length).to eq(y.length)
      expect(ulps(x, y)).to be < 2.4e-7
    end

    it 'keeps a biased range: (wave * amp + offset) * gain * node' do
      a = 110.hz.saw.at(0.2..0.9).gain(0.37).at(env)
      expect(a).to be_a(MB::Sound::Tone)
      x = collect(a)
      y = collect(110.hz.saw.at(0.2..0.9) * 0.37 * env)
      expect(ulps(x, y)).to be < 2.4e-7
      # The offset is scaled too: the output at a sustain of 0.5 averages
      # 0.55 * 0.37 * 0.5, not 0.37 * 0.5 * ramp + 0.55
      expect(x[3000...3870].mean).to be_within(0.01).of(0.55 * 0.37 * 0.5)
    end

    it 'merges an LFO with a numeric gain on a feedback sine' do
      a = 220.hz.fm_feedback(1.5).gain(0.81).at(3.hz.lfo.at(0.2..1.3))
      expect(a).to be_a(MB::Sound::Tone)
      expect(ulps(collect(a), collect(220.hz.fm_feedback(1.5).gain(0.81) * 3.hz.lfo.at(0.2..1.3)))).to be < 2.4e-7
    end

    it 'raises (live_error) when the gain is already a node, and multiplies after the tone live' do
      expect { 220.hz.saw.gain(env).at(env) }.to raise_error(ArgumentError, /already has a gain node/)
      allow(MB::Sound).to receive(:live?).and_return(true)
      b = nil
      expect { b = 220.hz.saw.gain(env).at(env) }.to output(/already has a gain node/).to_stderr
      expect(b).to be_a(MB::Sound::GraphNode::Multiplier)
      expect(collect(b)).to eq(collect(220.hz.saw.gain(env) * env))
    end

    it 'multiplies after phasors and playing tones instead of failing' do
      expect(100.hz.phasor.at(env)).to be_a(MB::Sound::GraphNode::Multiplier)
      t = 220.hz.saw
      t.sample(10)
      expect(t.at(env)).to be_a(MB::Sound::GraphNode::Multiplier)
      expect(t.output_gain).to be_nil
    end

    it 'prints back as .at(node) and round trips through a graph document' do
      MB::Sound.seed(1)
      g = 220.hz.saw.at(0.3).at(MB::Sound.adsr(0.01, 0.05, 0.5, 0.02, hold: 0.08))
      expect(g.to_ruby).to include("220.hz.saw.at(0.3).at(adsr(0.01, 0.05, 0.5, 0.02, hold: 0.08))")
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g, name: 'at'))
      expect(loaded).to be_a(MB::Sound::Tone)
      expect(collect(loaded)).to eq(collect(220.hz.saw.at(0.3) * env))

      merged = 110.hz.saw.at(0.2..0.9).gain(0.37).at(MB::Sound.adsr(0.01, 0.05, 0.5, 0.02, hold: 0.08))
      text = merged.to_ruby
      expect(text).to include("110.hz.saw.at(0.2..0.9).gain(0.37).at(adsr(0.01, 0.05, 0.5, 0.02, hold: 0.08))")
      loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(merged, name: 'at'))
      expect(collect(loaded)).to eq(collect(110.hz.saw.at(0.2..0.9).gain(0.37).at(env)))
    end
  end

  it 'raises for phasors and bad values' do
    expect { 100.hz.phasor.gain(0.5) }.to raise_error(ArgumentError, /phasor/)
    expect { 100.hz.gain('x') }.to raise_error(ArgumentError)
  end
end
