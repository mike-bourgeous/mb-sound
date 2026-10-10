RSpec.describe(MB::Sound::Arrangement) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:set) { session.arrangement }

  # One note per bar, so a track's output is its note number
  let(:a1) { MB::Sound.seq(MB::Sound::C3).n1.loop }
  let(:a2) { MB::Sound.seq(MB::Sound::D3).n1.loop }
  let(:b1) { MB::Sound.seq(MB::Sound::C4).n1.loop }

  after { session.close }

  # Runs the block with +session+ as the current session.
  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  # Returns [sample index, value] for each change in +data+.
  def changes(data)
    data.to_a.each_with_index.select { |v, i| i == 0 || v != data[i - 1] }.map { |v, i| [i, v.round(3)] }
  end

  def player(name)
    session.instance_variable_get(:@players).values.select { |p| p.name == name && p.current? }.last
  end

  before do
    set.track(:a) { |c| c.number }
    set.track(:b) { |c| c.number * 100 }
    set.scene(:one, a: a1)
    set.scene(:two, a: a2, b: b1)
  end

  it 'launches scenes on the next bar, changing only what differs' do
    set.go(:one, at: :now)
    run(1600)
    graph = player(:a).input

    entry = set.go(:two)
    expect(entry.to_s).to eq('scene :two lands 2:1 (queued)')

    data = run(96000)
    expect(changes(data)).to eq([[0, 48], [96000 - 1600, 50 + 6000]])
    expect(player(:a).input).to equal(graph) # swapped, not rebuilt

    # Launching the same scene again changes nothing
    set.go(:two)
    expect(session.queued.map(&:kind)).to eq([:scene])
    expect(set.current_scene).to eq(:two)
  end

  it 'stops tracks the scene leaves out, with a declick for others: :cut, unless others: :keep' do
    set.scene(:keep_a, b: b1, others: :keep)
    set.scene(:one_cut, a: a1, others: :cut)
    set.go(:two, at: :now)
    run(800)
    set.go(:one_cut)
    data = run(96000)
    bar = 96000 - 800
    expect(data[bar - 1]).to eq(50 + 6000)
    expect(data[bar + 240..].to_a.uniq).to eq([48]) # b faded out over 5 ms
    expect(session.stopped.keys).to eq([:b])

    set.go(:keep_a)
    run(96000)
    expect(run(800)[-1]).to eq(48 + 6000)
  end

  it 'uses each track\'s launch quantization, then the scene\'s, then the set\'s' do
    set.track(:b, q: 2) { |c| c.number * 100 }
    set.go(:one, at: :now)
    run(800)
    set.go(:two)
    data = run(96000 * 2)
    expect(changes(data)).to eq([[0, 48], [96000 - 800, 50], [192000 - 800, 50 + 6000]])
  end

  it 'lands launches inside scheduled blocks at the block time' do
    set.go(:one, at: :now)
    within { MB::Sound.at_bar(3) { MB::Sound.go(:two) } }
    data = run(96000 * 3)
    expect(changes(data)).to eq([[0, 48], [192000, 50 + 6000]])
  end

  it 'runs a scene block at the launch time' do
    set.scene(:three, a: a1) { |t| MB::Sound.bg(:x, 0.5.constant, fade: 0) }
    set.go(:one, at: :now)
    run(800)
    set.go(:three)
    data = run(96000)
    expect(changes(data)).to eq([[0, 48], [96000 - 800, 48.5]])
  end

  it 'plays a clip on a track with bg' do
    within do
      MB::Sound.bg(:b, b1)
    end
    expect(set.tracks[:b].clip).to equal(b1)
    expect(run(800)[0]).to eq(6000)
  end

  it 'keeps tracks and mute groups in one namespace, raising for collisions in scripts' do
    expect { session.mute_group(:a, :b) }.to raise_error(ArgumentError, /:a is already a track/)
    session.mute_group(:both, :a, :b)
    expect { set.track(:both) { |c| c.number } }.to raise_error(ArgumentError, /:both is already a group/)
    expect { set.scene(:bad, both: a1) }.to raise_error(ArgumentError, /:both is a group, not a track/)
    expect { set.track(:master) { |c| c.number } }.to raise_error(ArgumentError, /reserved/)
  end

  it 'warns instead of raising in live mode' do
    MB::Sound.live = true
    expect { expect(set.track(:a, 1.constant)).to eq(:a) }.not_to output.to_stderr # same kind again is fine
    session.mute_group(:grp, :a)
    expect { expect(set.track(:grp) { |c| c.number }).to be_nil }.to output(/already a group/).to_stderr
    expect { expect(set.go(:nope)).to be_nil }.to output(/No scene :nope/).to_stderr
  ensure
    MB::Sound.live = false
  end

  it 'raises for scenes naming unknown tracks when launched' do
    set.scene(:typo, c: a1)
    expect { set.go(:typo) }.to raise_error(ArgumentError, /:c, which is not a track/)
  end

  it 'lists tracks and scenes' do
    set.label(a1: a1, a2: a2)
    set.go(:one, at: :now)
    expect(set.track_info).to eq(a: 'q:1 a1 (playing)', b: 'q:1 no clip (stopped)')
    expect(set.scene_info).to eq(one: '▶ a:a1', two: 'a:a2 b:seq')
  end

  it 'counts plain numbers as bars and accepts Durations for launch points' do
    transport.bar_length = 3/4r
    set.go(:one, at: :now)
    run(800)
    expect(set.resolve(2)).to eq(3/2r)
    expect(set.resolve(MB::Sound::Sequence::Duration.new(1/4r))).to eq(1/4r)
    expect(set.resolve(:bar)).to eq(3/4r)
  end
end
