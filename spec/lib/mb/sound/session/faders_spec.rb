RSpec.describe(MB::Sound::Session::Faders) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames, a beat 24000
  def new_session(channels: 1)
    out = MB::Sound::NullOutput.new(channels: channels, sleep: false)
    MB::Sound::Session.new(
      master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      channels: channels, buffer_size: 800, realtime: false, raise_errors: true
    )
  end

  before { @sessions = [] }
  after { @sessions.each(&:close) }

  def session
    @session ||= new_session.tap { |s| @sessions << s }
  end

  # Runs the block in +s+'s context, then renders +frames+ frames in
  # buffers of +sizes+ (cycled); returns the first channel of the mix.
  def run(frames, sizes = [800], s: session, &setup)
    MB::Sound::Session.with_context(session: s) do
      setup&.call(s)
      out = []
      left = frames
      sz = sizes.cycle
      while left > 0
        n = [sz.next, left].min
        out << s.process_buffer(n)[0].dup
        left -= n
      end
      SpecBuffers.join(out)
    end
  end

  it 'is unity until set: no level knob, the same samples' do
    data = run(9600) { |s| s.add(0.5.constant, name: :a, on: :now) }
    expect(data.to_a.uniq).to eq([0.5])
    expect(session.knobs).to be_empty
    expect(session.levels).to eq({})
    expect(session.level(:a)).to eq(0.db)
  end

  it 'sets, ramps, and follows on exact frames at any buffer size' do
    results = [[800], *slow_tier([[367, 368], [7, 128, 333]])].map { |sizes|
      s = new_session.tap { |x| @sessions << x }
      run(3 * 96000, sizes, s: s) { |ss|
        ss.add(1.constant, name: :a, on: :now)
        ss.level(:a, -6.db, start_time: 1/16r)
        ss.level(:a, 0, over: 1/4r, start_time: 1r)
        ss.level(:a, 2.0, start_time: 2r)
      }
    }
    results.each { |d| expect(d).to eq(results[0]) }
    d = results[0]
    expect(d[0]).to eq(1)
    expect(d[6000 + 480]).to be_within(1e-6).of(-6.db) # (after the 5 ms glide)
    expect(d[96000 + 12000]).to be_within(1e-4).of(-6.db / 2) # halfway down the ramp
    expect(d[96000 + 24000...192000].abs.max).to eq(0)
    expect(d[192000 + 480..].to_a.uniq).to eq([2.0])
  end

  it 'turns by the track name, takes scene values in gains and level knob names, and lists them' do
    data = run(3 * 96000) { |s|
      MB::Sound.track(:pad, 1.constant)
      MB::Sound.scene(:a, pad: :on)
      MB::Sound.scene(:quiet, pad: -12.db, others: :keep)
      MB::Sound.scene(:half, "pad/level": [0.5, over: 1/4r], others: :keep)
      MB::Sound.go(:a, on: :now)
      MB::Sound.at_bar(2) { MB::Sound.go(:quiet) }
      MB::Sound.at_bar(3) { MB::Sound.go(:half) }
    }
    expect(data[1000]).to eq(1)
    expect(data[96000 + 960]).to be_within(1e-6).of(-12.db)
    expect(data[192000 + 24000 + 10]).to be_within(1e-6).of(0.5)
    expect(session.control_name(:pad)).to eq(:"pad/level")
    expect(session.levels).to eq({ pad: MB::Sound::Decibels.new(-6.02) })
    expect(session.arrangement.track_info[:pad]).to include('level -6.02.db')
    expect(MB::Sound::UI::Poll.level_db(session, :pad)).to eq(-6.0) # (the tracks pane's TrackInfo#level)
    expect(MB::Sound::UI::Poll.level_db(session, :other)).to be_nil
  end

  it 'is the console command `level`, journaled and undoable' do
    MB::Sound::Session.with_context(session: session) do
      session.add(1.constant, name: :a, on: :now)
      entry = MB::Sound.level(:a, 0.25)
      expect(entry.to_s).to match(/turn :"a\/level" landed/)
      session.process_buffer
      expect(MB::Sound.level(:a)).to eq(MB::Sound::Decibels.new(-12.04))
      expect(MB::Sound.level).to eq({ a: MB::Sound::Decibels.new(-12.04) })
      MB::Sound.undo(on: :now)
      session.process_buffer
      expect(MB::Sound.level(:a)).to eq(0.db)
      expect { MB::Sound.level(:a, -1) }.to raise_error(ArgumentError, /linear gains .* -6.db/)
    end
  end

  it 'applies to monitors and cue players through their track, and to readers before the mute' do
    data = run(48000) { |s|
      s.add(1.constant, name: :"lead/live", on: :now)
      s.add(0.5.constant, name: :kick, on: :now)
      s.add(MB::Sound.bus(:kick) * 0.1, name: :probe, on: :now)
      s.level(:lead, 0.5)
      s.level(:kick, 0.5)
      s.mute(:kick)
    }
    expect(data[24000]).to be_within(1e-6).of(0.5 + 0.025) # monitor at :lead's level, probe reading the muted kick after its level
  end

  it 'keeps a trigger track\'s level as its fader (`level :pump, 0` stops the pump)' do
    line = MB::Sound.grid(16, 'x...x...x...x.x.').loop
    data = run(2 * 96000) { |s|
      MB::Sound.sidechain(:pump, line, on: :now)
      s.add(MB::Sound.bus(:pump), name: :probe, on: :now)
      MB::Sound.at_bar(2) { MB::Sound.level(:pump, 0) }
    }
    expect(data[0]).to eq(0.75)
    expect(data[96000 + 960..].abs.max).to eq(0)
    expect(session.knobs.keys).to eq([:"pump/level"])
  end

  it 'goes into stems and set documents, which load it back' do
    text = nil
    run(9600) { |s|
      MB::Sound.track(:pad, 1.constant)
      MB::Sound.scene(:a, pad: :on)
      MB::Sound.go(:a, on: :now)
      MB::Sound.level(:pad, -6.db)
    }
    MB::Sound::Session.with_context(session: session) { text = MB::Sound::GraphIO::SetWriter.new(session.arrangement).to_s }
    expect(text).to include('knob :"pad/level", (0.0..4.0).at(0.5011872336272722)')
    s2 = new_session.tap { |x| @sessions << x }
    data = run(9600, s: s2) { |s| MB::Sound::GraphIO.load(text, session: s); MB::Sound.go(:a, on: :now) }
    expect(data[4800]).to be_within(1e-6).of(-6.db)
  end

  it 'replays from takes bit for bit' do
    lines = {
      0 => ['track :pad, 220.hz.triangle * 0.5', 'go_pad = scene(:a, pad: :on)', 'go :a, on: :now'],
      13 => ['level :pad, -9.db, over: 1/4r'],
      70 => ['level :pad, 0.1, on: :beat'],
    }
    s = new_session
    @sessions << s
    b = MB::Sound::Take.console_binding
    out = []
    t = MB::Sound::Take.new(session: s)
    120.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { t.line(code, b) } }
      out << s.process_buffer[0].dup
    end
    live = SpecBuffers.join(out)
    data = []
    t.replay.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: [367], tail: 0) { |mix| data << mix[0].dup }
    data = SpecBuffers.join(data)
    expect((data[0...live.length] - live).abs.max).to be < 1e-6
  end
end
