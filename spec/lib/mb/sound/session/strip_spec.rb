RSpec.describe(MB::Sound::Session::Strip) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  # Renders +frames+ frames in buffers of +sizes+ (cycled) and returns the
  # mix.
  def run(frames, sizes = [800])
    out = []
    left = frames
    sizes = sizes.cycle
    while left > 0
      n = [sizes.next, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    out.reduce(:concatenate)
  end

  def player(name)
    session.instance_variable_get(:@players).values.find { |p| p.name == name }
  end

  it 'mutes now with a 5 ms declick ramp starting at the next buffer' do
    session.add(1.constant, name: :x)
    run(1600)
    session.mute(:x)
    expect(session.muted?(:x)).to eq(true)

    data = run(1600)
    expect(data[0]).to eq(1)
    expect(data[120]).to be_within(1e-6).of(0.5)
    expect(data[239]).to be_within(1e-6).of(1 / 240.0)
    expect(data[240..].to_a.uniq).to eq([0])
  end

  it 'stops rendering a muted player (it sleeps) and lists it as muted' do
    session.add(1.constant, name: :x)
    session.mute(:x)
    run(1600)
    expect(player(:x).asleep).to eq(true)
    expect(session.players[:x]).to match(/muted/)

    expect(player(:x).input).not_to receive(:read)
    expect(run(8000).to_a.uniq).to eq([0])
  end

  it 'wakes on the unmute sample with its clips back in phase with the timeline' do
    clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::D3, MB::Sound::E3, MB::Sound::F3).n4.loop
    session.add(clip.number, name: :x)
    run(800)
    session.mute(:x)
    run(96000 + 24000 - 1600) # sleeps through more than a bar

    session.unmute(:x, at: :bar)
    data = run(96000 * 2)
    idx = 192000 - 119200 # bar 3 starts at frame 192000; 119200 frames played
    expect(data[0...idx].to_a.uniq).to eq([0])
    # The 5 ms ramp from the bar line, on the clip's first note (C3 = 48)
    expect(data[idx]).to eq(0)
    expect(data[idx + 240]).to eq(MB::Sound::C3.number)
    expect(data[idx + 24000]).to eq(MB::Sound::D3.number)
  end

  it 'mutes at a launch point over a fade in bars (synced fade)' do
    session.add(1.constant, name: :x)
    run(800)
    session.mute(:x, at: :bar, fade: 1/2r)
    expect(session.strip_info[:queued].map(&:kind)).to eq([:mute])

    data = run(96000 * 2)
    start = 96000 - 800
    expect(data[start - 1]).to eq(1)
    expect(data[start]).to eq(1)
    expect(data[start + 24000]).to be_within(1e-6).of(0.5)
    expect(data[start + 48000..].to_a.uniq).to eq([0])
  end

  it 'solos players, silencing the others, and clears solos' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    session.add(4.constant, name: :c)
    run(800)

    session.solo(:b, :c)
    expect(run(1600)[-1]).to eq(6)
    expect(session.audible?(:a)).to eq(false)

    session.solo
    expect(run(1600)[-1]).to eq(7)
    expect(session.strip_info[:soloed]).to eq([])
  end

  it 'clears every solo that has landed when the clear lands, even one queued before it' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    run(800)
    session.solo(:a, start_time: 1/2r)
    session.command('solo') { session.solo(start_time: 3/4r) } # clears all: :a's solo hasn't landed yet
    expect(session.strip_info[:soloed]).to eq([])
    data = run(96000)
    expect(data[48000 - 800 + 300]).to eq(1)
    expect(data[72000 - 800 + 300]).to eq(3)
    expect(session.strip_info[:soloed]).to eq([])
    expect(session.journal.changes.last).to have_attributes(kind: :unsolo, subject: :strip, status: :landed)

    session.undo(at: :now)
    expect(run(1600)[-1]).to eq(1)
  end

  it 'mutes groups of players' do
    session.add(1.constant, name: :a)
    session.add(2.constant, name: :b)
    session.add(4.constant, name: :c)
    session.mute_group(:breakdown, :a, :b)
    session.mute(:breakdown)
    expect(run(1600)[-1]).to eq(4)
    session.unmute(:breakdown)
    expect(run(1600)[-1]).to eq(7)
    expect(session.mute_groups).to eq(breakdown: [:a, :b])
  end

  it 'starts a graph replacing a muted one muted' do
    session.add(1.constant, name: :x)
    session.mute(:x)
    run(1600)
    session.add(2.constant, name: :x, at: :now)
    expect(run(1600).to_a.uniq).to eq([0])
    session.unmute(:x)
    expect(run(1600)[-1]).to eq(2)
  end

  it 'lands mutes, solos, and fades on the same samples at any buffer size' do
    renders = [[800], [367, 368], [64], [1001, 13]].map { |sizes|
      t = MB::Sound::Sequence::Transport.new(bpm: 120)
      s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: t, channels: 1, buffer_size: 800, realtime: false, raise_errors: true, fade_in: 1/4r, fade_out: 1/2r)
      # Sources that don't depend on the buffer size themselves (Tone phases
      # accumulate per buffer, differing by ~1e-12 across buffer sizes)
      s.add(MB::Sound.seq(MB::Sound::C3, MB::Sound::G3).n8.loop.number, name: :a)
      s.add(0.25.constant, name: :b, start_time: 1/8r)
      s.mute(:a, start_time: 1/3r, fade: 1/16r)
      s.solo(:a, start_time: 1/2r)
      s.unmute(:a, start_time: 5/8r)
      s.remove(:a, time: 7/8r)
      out = []
      left = 96000 * 2
      cycle = sizes.cycle
      while left > 0
        n = [cycle.next, left].min
        out << s.process_buffer(n)[0].dup
        left -= n
      end
      s.close
      out.reduce(:concatenate)
    }

    expect(renders[0].abs.max).to be > 40
    renders[1..].each do |r|
      expect((r - renders[0]).abs.max).to eq(0)
    end
  end
end
