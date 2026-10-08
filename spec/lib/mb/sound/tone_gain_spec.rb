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
    'a band-limited ramp with #at' => -> { 220.hz.ramp.at(0.3) },
    'a ramp with an offset range' => -> { 110.hz.ramp.at(0.2..0.9) },
    'a pulse with pwm' => -> { 330.hz.pwm(0.3).square },
    'a complex sine' => -> { 220.hz.complex_sine },
    'a complex ramp (BLIT)' => -> { 220.hz.complex_ramp },
    'a synced square' => -> { 150.hz.square.sync(ratio: 2.3) },
    'a feedback sine' => -> { 220.hz.feedback(1.5) },
    'a wavetable' => -> { 220.hz.wavetable(:saw, scan: 0.5) },
    'a tone with resets and FM' => -> {
      t = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(6000).tap { |a| a[[50, 700, 3000]] = 1 }])
      200.hz.ramp.fm(5.hz.lfo.at(20)).reset(t)
    },
  }.each do |name, make|
    it "equals tone * gain bit for bit for #{name}, and C equals Ruby" do
      a = collect(make.call.gain(env))
      b = collect(make.call * env)
      expect(a.length).to be_between(4000, 6000)
      expect(a).to eq(b)

      c = make.call.gain(env)
      r = []
      [300, 1, 511].each { |n| r << c.sample_ruby(n).dup }
      d = make.call.gain(env)
      e = [300, 1, 511].map { |n| d.sample_c(n).dup }
      # (the naive complex sine's Ruby mirror differs by ~1e-16 already)
      if name == 'a complex sine'
        expect(r.zip(e).map { |x, y| (x - y).abs.max }.max).to be < 1e-6
      else
        expect(r).to eq(e)
      end
    end
  end

  it 'equals tone * number for a constant gain' do
    expect(collect(220.hz.ramp.gain(0.3), [1000])).to eq(collect(220.hz.ramp * 0.3, [1000]))
    expect(collect(220.hz.ramp.amp(-2), [1000])).to eq(collect(220.hz.ramp * -2, [1000]))
  end

  it 'leaves the output unchanged without a gain (and with gain(nil))' do
    expect(collect(220.hz.ramp.gain(0.5).gain(nil), [1000])).to eq(collect(220.hz.ramp, [1000]))
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
    a = collect(220.hz.feedback(1.5, gain: 0.5).gain(env), [2000])
    b = collect(220.hz.feedback(1.5, gain: 0.5) * env, [2000])
    expect(a).to eq(b)
  end

  it 'lists a node gain in #sources and has accessors' do
    e = env
    t = 100.hz.gain(e)
    expect(t.sources.keys).to include(:gain)
    expect(100.hz.gain(0.5).output_gain).to eq(0.5)
    expect(100.hz.gain(0.5).sources.keys).not_to include(:gain)
  end

  it 'raises for phasors and bad values' do
    expect { 100.hz.phasor.gain(0.5) }.to raise_error(ArgumentError, /phasor/)
    expect { 100.hz.gain('x') }.to raise_error(ArgumentError)
  end
end
