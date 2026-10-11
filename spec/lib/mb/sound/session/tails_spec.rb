RSpec.describe(MB::Sound::Session::Tails) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:buffer) { 800 }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: buffer) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: buffer, realtime: false, raise_errors: true) }
  let(:set) { session.arrangement }

  # One whole-bar note per bar
  let(:c3) { MB::Sound.seq(MB::Sound::C3).n1.loop }

  after { session.close }

  def run(frames, size = buffer)
    out = []
    left = frames
    while left > 0
      n = [size, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    out.reduce(:concatenate)
  end

  def player(name)
    session.instance_variable_get(:@players).values.select { |p| p.name == name }.last
  end

  def rung_out
    session.journal.changes.select { |e| e.kind == :rung_out }
  end

  # A track whose notes release over a tenth of a second
  def env_track(name = :a)
    set.track(name) { |c| n = c.notes; n.amp_env(0, 0, 1, 0.1, curve: :linear) * 0.5 }
  end

  it 'rings a dropped clip track out: notes stop on the launch sample, the tail plays, then it sleeps' do
    env_track
    set.scene(:one, a: c3)
    set.scene(:none)
    set.go(:one, on: :now)
    run(800)
    entry = set.go(:none)
    expect(entry.to_s).to eq('scene :none lands 2:1 (queued)')

    data = run(96000 * 2)
    stop = 96000 - 800
    level = data[stop - 1]
    expect(level).to be > 0.1
    expect(data[stop + 100]).to be_between(0.01, level).exclusive # releasing, not cut
    release_end = stop + 4800
    expect(data[release_end..].abs.max).to eq(0)

    # Asleep once quiet for RING_QUIET_SECONDS after the last audible sample
    expect(session.players).to eq({})
    expect(session.stopped.keys).to eq([:a])
    expect(rung_out.length).to eq(1)
    expect(rung_out[0].data[:capped]).to eq(false)
    expect(rung_out[0].data[:seconds]).to be_within(0.01).of(0.1 + described_class::RING_QUIET_SECONDS)

    # The stop is journaled as a ring
    stop_entry = session.journal.changes.find { |e| e.kind == :stop }
    expect(stop_entry.data).to eq({ ring: true })
  end

  [800, 367, 64].each do |size|
    it "rings out to the same sample with #{size}-frame buffers" do
      env_track
      set.scene(:one, a: c3)
      set.scene(:none)
      set.go(:one, on: :now)
      run(800, size == 800 ? 800 : 400)
      set.go(:none, at: MB::Sound.bar(2))
      data = run(96000 * 2, size)
      expect(data[96000 - 800 + 100]).to be > 0

      # The same frame at every buffer size (a few samples before the end
      # of the release fall below -90 dB)
      frames = rung_out[0].lands.frame
      expect(frames).to be_within(5).of(96000 + 4800 + 48000)
      $tails_spec_frames ||= frames
      expect(frames).to eq($tails_spec_frames)
    end
  end

  it 'fades a tail out after MAX_TAIL_SECONDS' do
    stub_const('MB::Sound::Session::Master::MAX_TAIL_SECONDS', 0.5)
    set.track(:a) { |c| c.notes.number } # holds the last note number forever
    set.scene(:one, a: c3)
    set.scene(:none)
    set.go(:one, on: :now)
    run(800)
    set.go(:none)
    data = run(96000 * 2)

    stop = 96000 - 800
    cap = stop + 24000
    expect(data[cap - 1]).to eq(48)
    fade = (MB::Sound::Session::Master::TAIL_FADE_SECONDS * 48000).round
    expect(data[cap + fade / 2]).to be_within(0.1).of(24)
    expect(data[cap + fade..].abs.max).to eq(0)
    expect(rung_out[0].data[:capped]).to eq(true)
    expect(session.stopped.keys).to eq([:a])
  end

  it 'fades graphs without clips over RING_DRONE_FADE bars' do
    set.track(:drone, 1.constant)
    set.scene(:one, drone: :on)
    set.scene(:none)
    set.go(:one, on: :now)
    run(800)
    set.go(:none)
    data = run(96000 * 2)
    stop = 96000 - 800
    length = (described_class::RING_DRONE_FADE * 96000).round
    expect(data[stop - 1]).to eq(1)
    expect(data[stop + length / 2]).to be_within(0.01).of(0.5)
    expect(data[stop + length..].abs.max).to eq(0)
  end

  it 'cuts with a declick for others: :cut and for a :cut value, and fades with fade:' do
    env_track(:a)
    env_track(:b)
    set.scene(:both, a: c3, b: c3)
    set.scene(:cut_all, others: :cut)
    set.scene(:cut_b, a: c3, b: :cut)
    set.go(:both, on: :now)
    run(800)
    set.go(:cut_b)
    run(96000 + 800)
    expect(session.stopped.keys).to eq([:b])
    expect(rung_out).to be_empty

    set.go(:cut_all)
    run(96000)
    expect(session.stopped.keys).to contain_exactly(:a, :b)
    expect(rung_out).to be_empty
  end

  it 'brings a ringing track back as the same graph when its scene returns' do
    env_track
    set.scene(:one, a: c3)
    set.scene(:none)
    set.go(:one, on: :now)
    run(800)
    graph = player(:a).input

    set.go(:none)
    run(96000)
    expect(session.ringing?(:a)).to eq(true)
    expect(session.players[:a]).to include('ringing out')

    set.go(:one, on: :beat) # half a second into the tail
    data = run(24000 - 800 + 1600)
    expect(player(:a).input).to equal(graph)
    expect(player(:a).current?).to eq(true)
    expect(session.ringing?(:a)).to eq(false)
    data = run(96000)
    # The next note plays on bar 3 (frame 192000)
    bar3 = 192000 - (800 + 96000 + 24000 - 800 + 1600)
    expect(data[bar3 - 1]).to eq(0)
    expect(data[bar3]).to be > 0.1
    run(96000 * 2)
    expect(rung_out).to be_empty
  end

  it 'brings a ringing track back with undo' do
    env_track
    set.scene(:one, a: c3)
    set.scene(:none)
    set.go(:one, on: :now)
    run(800)
    graph = player(:a).input
    set.go(:none)
    run(96000)

    session.undo(on: :now)
    run(800)
    expect(player(:a).input).to equal(graph)
    expect(player(:a).current?).to eq(true)
    expect(session.ringing?(:a)).to eq(false)
  end

  it 'resumes a ringing player and a sleeping one with their real clips' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(800)
    session.remove(:a, ring: true)
    run(800)
    expect(session.resumable?(:a)).to eq(true)
    source = player(:a).timeline_nodes.grep(MB::Sound::MIDI::ClipSource).first
    expect(source.ring_clip).to equal(c3)

    run(96000)
    expect(session.stopped.keys).to eq([:a])
    expect(source.clip).to equal(c3)
    expect(source.ring_clip).to be_nil

    session.resume(:a, on: :bar, fade: 0)
    data = run(96000)
    expect(data[-1]).to be > 0.1
  end

  it 'puts a muted ringing player to sleep right away' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(800)
    session.mute(:a)
    run(800)
    session.remove(:a, ring: true)
    run(1600)
    expect(session.stopped.keys).to eq([:a])
  end

  it 'lets a cut take over from a ringing tail' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(800)
    session.remove(:a, ring: true)
    run(800)
    session.remove(:a, fade: 0)
    expect(run(800).abs.max).to eq(0)
    expect(session.stopped.keys).to eq([:a])
    source = session.instance_variable_get(:@stopped)[:a].timeline_nodes.grep(MB::Sound::MIDI::ClipSource).first
    expect(source.clip).to equal(c3)
  end

  it 'rings out from the console with stop ring: true' do
    MB::Sound::Session.with_context(session: session) do
      env_track
      set.scene(:one, a: c3)
      set.go(:one, on: :now)
      run(800)
      MB::Sound.stop(:a, ring: true)
    end
    run(800)
    expect(session.ringing?(:a)).to eq(true)
  end
end
