RSpec.describe(MB::Sound::GraphNode::Rotary, :aggregate_failures) do
  let(:mod) { MB::Sound::GraphNode::Rotary }

  def collect(node, total, size = 800)
    sizes = Array(size).cycle
    out = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      buf = node.sample(len)
      break if buf.nil?
      out << buf.dup
      n += buf.length
    end
    SpecBuffers.join(out)
  end

  # Both sides of a bundle collected in turn, buffer by buffer.
  def collect_stereo(bundle, total, size = 800)
    sizes = Array(size).cycle
    l = []
    r = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      a = bundle.outputs[0].sample(len)
      b = bundle.outputs[1].sample(len)
      break if a.nil? || b.nil?
      l << a.dup
      r << b.dup
      n += a.length
    end
    [SpecBuffers.join(l), SpecBuffers.join(r)]
  end

  # The peak of +data+ in each +window+-sample block.
  def envelope(data, window)
    (data.length / window).times.map { |i| data[(i * window)...((i + 1) * window)].abs.max }
  end

  it 'splits at the crossover with a flat sum (rotors held still, no Doppler or tremolo)' do
    [100, 800, 5000].each do |f|
      l, r = collect_stereo(f.hz.sine.at(0.5).rotary(doppler: 0, tremolo: 0), 24000)
      expect(l[12000..].abs.max).to be_within(0.005).of(0.5), "#{f} Hz"
      expect(r).to eq(l)
    end
  end

  it "modulates the horn's level by its tremolo depth at its speed, the microphones a spread apart" do
    # 5 kHz is all horn; at the slow speed (0.8 Hz) the level swings from 1 to 1 - 0.5
    # (from 0.1 s: the crossover's highpass rings at the sine's start)
    l, r = collect_stereo(5000.hz.sine.at(0.5).rotary(doppler: 0, spread: 0.5), 96000)
    el = envelope(l[4800..], 480)
    er = envelope(r[4800..], 480)
    expect(el.max).to be_within(0.01).of(0.5)
    expect(el.min).to be_within(0.01).of(0.25)
    # opposite microphones: one loud while the other is quiet
    i = el.index(el.max)
    expect(er[i]).to be_within(0.02).of(0.25)
    # 0.8 Hz: the loudest blocks 1.25 s apart
    peaks = el.each_index.select { |k| k > 0 && k < el.length - 1 && el[k] >= el[k - 1] && el[k] > el[k + 1] && el[k] > 0.49 }
    expect((peaks[1] - peaks[0]) * 480 / 48000.0).to be_within(0.03).of(1.25) if peaks.length > 1
  end

  it "sweeps the horn's delay by the Doppler depth around its center" do
    t = MB::Sound::GraphNode::ModulationLfo.tone(6.7, shape: :sine, phase: 0.25, sample_rate: 48000)
    expect(mod.rotation(6.7, 0.25, 48000).sample(1)[0]).to be_within(1e-6).of(1) # (cos 0: pointing at the microphone)
    expect(t.sample(10).max).to be <= 1
    # through the node: a 6 kHz sine's pitch wavers by 2 pi f_rot A f at the fast speed
    l, = collect_stereo(6000.hz.sine.at(0.5).rotary(:whirl, tremolo: 0, spread: 0), 48000)
    x = Numo::DFloat.cast(l[4800...48000])
    # instantaneous frequency from zero crossings
    crossings = (1...x.length).select { |i| x[i] >= 0 && x[i - 1] < 0 }.map { |i| i - x[i] / (x[i] - x[i - 1]) }
    freqs = crossings.each_cons(2).map { |a, b| 48000.0 / (b - a) }
    dev = 2 * Math::PI * 6.7 * mod::HORN_DOPPLER * 6000
    expect(freqs.max - 6000).to be_within(dev * 0.15).of(dev)
    expect(6000 - freqs.min).to be_within(dev * 0.15).of(dev)
  end

  it 'glides each rotor between its speeds at its own rate (the horn fast, the drum slow)' do
    step = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4800).concatenate(Numo::SFloat.ones(48000 * 8))])
    horn = mod.rotor_rate(step, *mod::HORN_SPEEDS, mod::HORN_RAMP, 48000)
    h = collect(horn, 4800 + 48000 * 2)
    expect(h[0]).to be_within(1e-4).of(0.8)
    expect(h[4800 + 24000]).to be_within(0.01).of(0.8 + 5.9 / 2) # halfway after half a second
    expect(h[4800 + 48000 + 10]).to be_within(1e-3).of(6.7)
    step = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4800).concatenate(Numo::SFloat.ones(48000 * 8))])
    drum = collect(mod.rotor_rate(step, *mod::DRUM_SPEEDS, mod::DRUM_RAMP, 48000), 4800 + 48000 * 6)
    expect(drum[4800 + 48000]).to be_within(0.01).of(0.67 + (5.7 - 0.67) / 5)
    expect(drum[4800 + 48000 * 5 + 10]).to be_within(1e-3).of(5.7)
    expect(mod.rotor_rate(1.0, *mod::HORN_SPEEDS, mod::HORN_RAMP, 48000)).to eq(6.7)
    expect(mod.rotor_rate(:stop, *mod::HORN_SPEEDS, mod::HORN_RAMP, 48000)).to eq(0)
  end

  it 'switches speed live from a node, the rotation staying continuous' do
    # slow for 0.5 s, then fast: 1.5 s later the horn turns at 6.7 Hz (its
    # level's peaks 1 / 6.7 s apart), and no sample jumps
    speed = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(24000).concatenate(Numo::SFloat.ones(120_000))])
    l, r = collect_stereo(5000.hz.sine.at(0.5).rotary(speed: speed, doppler: 0), 144_000)
    expect((l[1..] - l[0...-1]).abs.max).to be < 0.4 # (a 5 kHz sine at 0.5 moves at most 0.33 per sample)
    expect(r.length).to eq(l.length)
    el = envelope(l[96_000..], 48)
    peaks = el.each_index.select { |k| k > 0 && k < el.length - 1 && el[k] >= el[k - 1] && el[k] > el[k + 1] && el[k] > 0.49 }
    gaps = peaks.each_cons(2).map { |a, b| (b - a) * 48 / 48000.0 }
    expect(gaps).not_to be_empty
    gaps.each { |g| expect(g).to be_within(0.004).of(1 / 6.7) }
  end

  it 'holds the rotors still with speed: :stop' do
    l, r = collect_stereo(5000.hz.sine.at(0.5).rotary(speed: :stop, spread: 0.25), 48000)
    el = envelope(l[4800..], 480)
    expect(el.max - el.min).to be < 0.002
    expect(r[4800..].abs.max).to be_within(0.01).of(0.5 * (1 - 0.25)) # a quarter turn: halfway between loud and quiet
  end

  it 'mixes a stereo input to its one input, and the dry signal back in with mix:' do
    st = MB::Sound.stereo(220.hz.saw.at(0.3), 330.hz.saw.at(0.3))
    a = collect_stereo(st.rotary, 4800)
    b = collect_stereo(((220.hz.saw.at(0.3) + 330.hz.saw.at(0.3)) * 0.5).rotary, 4800)
    expect(a).to eq(b)
    dry = collect_stereo(220.hz.saw.at(0.3).rotary(mix: 0), 4800)
    expect(dry[0]).to eq(collect(220.hz.saw.at(0.3), 4800))
  end

  it 'ends both microphones together, a short tail after the input' do
    l, r = collect_stereo(220.hz.saw.at(0.3).until(0.5).rotary(:whirl), 200_000)
    expect(l.length).to eq(24000 + (mod::TAIL * 48000).round)
    expect(r.length).to eq(l.length)
  end

  it 'gives the same output at any buffer size, switching speed' do
    make = -> { 220.hz.saw.at(0.3).rotary(speed: 0.7.hz.lfo.square.at(0..1), horn: -2.db) }
    expect(collect_stereo(make.(), 24000, [1, 7, 128, 33])).to eq(collect_stereo(make.(), 24000, 800))
  end

  it 'has its presets in the library and renders each bounded' do
    expect(mod.preset_names).to include(:cabinet, :whirl, :chorale)
    expect(MB::Sound::L.fx.rotary.names).to include(:cabinet, :whirl)
    mod.preset_names.each do |name|
      collect_stereo(220.hz.saw.at(0.5).rotary(name), 9600).each do |b|
        expect(b.isfinite.all?).to eq(true)
        expect(b.abs.max).to be_between(0.1, 1.5), "#{name}: #{b.abs.max}"
      end
    end
  end

  it 'loads back from Ruby and from a graph document with the same samples' do
    g = -> { 220.hz.saw.at(0.3).until(0.2).rotary(:whirl, spread: 0.4, horn: -3.db) }
    code = g.().to_ruby
    expect(code).to include('rotary(:whirl, spread: 0.4, horn: -3.db)')
    ref = RecipeHelpers.render(g.(), buffers: 20)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(RecipeHelpers.eval_recipe(code), buffers: 20))).to eq(0)
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g.()))
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(loaded, buffers: 20))).to eq(0)
    expect(220.hz.saw.rotary_speaker.channel_count).to eq(2)
  end

  it 'rejects bad arguments with helpful messages' do
    expect { 220.hz.saw.rotary(sped: :fast) }.to raise_error(ArgumentError, /sped.*speed/)
    expect { 220.hz.saw.rotary(:cabnet) }.to raise_error(ArgumentError, /cabinet/)
    expect { 220.hz.saw.rotary(speed: :medium) }.to raise_error(ArgumentError, /:slow/)
    expect { 220.hz.saw.rotary(speed: 2) }.to raise_error(ArgumentError, /0..1/)
    expect { 220.hz.saw.rotary(crossover: 30000) }.to raise_error(ArgumentError, /Nyquist/)
    expect { 220.hz.saw.rotary(ramp: 0) }.to raise_error(ArgumentError, /ramp/)
    expect { 220.hz.saw.rotary(doppler: 20) }.to raise_error(ArgumentError, /tail/)
    expect { 220.hz.saw.rotary(0.5) }.to raise_error(ArgumentError, /preset name/)
  end
end
