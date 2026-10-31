RSpec.describe(MB::Sound::GraphNode::TapeEcho) do
  # Renders every output of +g+ (a node or bundle) in buffers cycling
  # through +sizes+ until they end or +limit+ samples.
  def render(g, sizes, limit)
    outs = g.is_a?(MB::Sound::GraphNode::Channels) ? g.outputs : [g]
    lists = outs.map { [] }
    n = 0
    i = 0
    while n < limit
      bufs = outs.map { |o| o.sample(sizes[i % sizes.length]) }
      break if bufs.all?(&:nil?)

      bufs.each_with_index { |b, k| lists[k] << b.dup if b }
      n += bufs.compact.map(&:length).max
      i += 1
    end
    lists.map { |l| SpecBuffers.join(l) }
  end

  def impulse
    1.constant.until(1.samples)
  end

  # Echo peaks: [offset from k * t, level] for the windows around k * t.
  def echoes(data, t, count)
    a = data.abs
    (1..count).map { |k|
      w = a[(k * t - t / 2)...(k * t + t / 2)]
      [w.max_index - t / 2, w.max]
    }
  end

  it 'has the :delay family presets in the library' do
    expect(described_class.preset_names).to include(:reel, :slapback, :ping_pong, :dub)
    expect(MB::Sound::L.fx.delay.names).to include(:reel, :slapback, :ping_pong, :dub)
    expect(MB::Sound::L.fx.delay.dub.about).to match(/dub/i)
  end

  it 'repeats about time apart, each repeat quieter and the default reel darker' do
    MB::Sound.seed(1)
    out, = render(impulse.tape_echo(:reel, mix: 1), [800], 120_000)
    t = 18_000 # 3.n16 at 120 BPM
    e = echoes(out, t, 4)
    e.each { |off, _| expect(off.abs).to be < 80 } # (the filters' and wobble's few ms)
    levels = e.map(&:last)
    expect(levels.each_cons(2).all? { |a, b| b < a }).to eq(true)
    expect(levels[0]).to be > 0.05
  end

  it 'bounces :ping_pong repeats left, right, left' do
    MB::Sound.seed(1)
    l, r = render(impulse.tape_echo(:ping_pong, mix: 1), [512], 60_000)
    t = 12_000 # 1.n8
    expect(l[(t - 200)...(t + 200)].abs.max).to be > 0.1
    expect(r[(t - 200)...(t + 200)].abs.max).to be < 1e-6
    expect(r[(2 * t - 200)...(2 * t + 200)].abs.max).to be > 0.02
    expect(l[(2 * t - 200)...(2 * t + 200)].abs.max).to be < 1e-6
    expect(l[(3 * t - 200)...(3 * t + 200)].abs.max).to be > 0.005
  end

  it 'gives the same samples at any buffer size' do
    make = -> {
      MB::Sound.seed(3)
      (220.hz.saw.at(0.3) * MB::Sound.adsr(0, 0.05, 0, 0)).tape_echo(:ping_pong, time: 0.05, feedback: 0.6)
    }
    ref = render(make.(), [800], 30_000)
    [[367, 368], [64], [1]].each do |sizes|
      next if sizes == [1] && !SPEC_SLOW
      out = render(make.(), sizes, 30_000)
      expect(out.map { |o| o[0...29_000] }).to eq(ref.map { |o| o[0...29_000] }), "at #{sizes}"
    end
  end

  it 'keeps the seed: the same graph twice gives the same samples' do
    a = MB::Sound.with_seed(9) { render(220.hz.saw.at(0.3).until(0.05).tape_echo(:dub, time: 0.03), [800], 20_000) }
    b = MB::Sound.with_seed(9) { render(220.hz.saw.at(0.3).until(0.05).tape_echo(:dub, time: 0.03), [800], 20_000) }
    expect(a).to eq(b)
  end

  it 'runs one tape per channel of a stereo input (unless :ping_pong)' do
    st = MB::Sound::GraphNode::Channels.new([220.hz.saw.at(0.3), 330.hz.saw.at(0.3)])
    expect(st.tape_echo(:reel).channel_count).to eq(2)
    expect(220.hz.saw.tape_echo(:reel)).not_to be_a(MB::Sound::GraphNode::Channels)
    expect(220.hz.saw.tape_echo(:ping_pong).channel_count).to eq(2)
  end

  # (delays-2: live value settings, knobs turn them without a rebuild)
  it 'takes nodes for tone, low_cut, drive, wow, and flutter: within float rounding of the numbers' do
    make = ->(**o) { MB::Sound.with_seed(4) { render((220.hz.saw.at(0.5) * MB::Sound.adsr(0, 0.05, 0, 0)).tape_echo(:dub, time: 0.03, **o), [800], 12_000)[0] } }
    ref = make.()
    { tone: 1800.0, low_cut: 300.0, drive: 2.5, wow: 0.5, flutter: 0.08 }.each do |k, v|
      out = make.(k => v.constant)
      expect((out - ref).abs.max).to be < 1e-5, "#{k}: #{(out - ref).abs.max}"
    end
    darker = make.(tone: 600.constant)
    expect((darker - ref).abs.max).to be > 0.01
    # (a drive node at 0 is nearly clean, divided by at least MIN_LIVE_DRIVE)
    clean = make.(drive: 0)
    expect((make.(drive: 0.constant) - clean).abs.max).to be < 1e-2
  end

  it 'prints itself back as Ruby' do
    expect(220.hz.saw.tape_echo(:dub, feedback: 0.6).to_ruby).to eq('220.hz.saw.tape_echo(:dub, feedback: 0.6)')
  end

  it 'raises with suggestions for unknown options, presets, and stereo modes' do
    expect { 1.constant.tape_echo(:reel, feedbak: 0.5) }.to raise_error(ArgumentError, /feedbak.*feedback/)
    expect { 1.constant.tape_echo(:dubb) }.to raise_error(ArgumentError, /dub/)
    expect { 1.constant.tape_echo(:reel, stereo: :wide) }.to raise_error(ArgumentError, /:mono or :ping_pong/)
  end
end
