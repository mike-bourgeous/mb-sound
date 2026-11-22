RSpec.describe(MB::Sound::MIDI::Destination, :aggregate_failures) do
  # 120 BPM at 48 kHz: a bar is 96000 frames, a quarter note 24000
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  def session_at(size)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                           channels: 1, buffer_size: size, realtime: false, raise_errors: true).tap { |s| @sessions << s }
  end

  before { @sessions = [] }
  after { @sessions.each(&:close) }

  # Runs +frames+ frames of +session+ in buffers of +size+ (the last one
  # shorter), calling the block (if any) with the session frame before each
  # buffer.
  def run(session, frames, size)
    done = 0
    while done < frames
      n = [size, frames - done].min
      yield done if block_given?
      session.process_buffer(n)
      done += n
    end
  end

  def riff
    MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, nil).n4.loop
  end

  it 'checks channels, programs, and banks, counting from 1' do
    expect { MB::Sound.midi_out(log: true, channel: 0) }.to raise_error(ArgumentError, /channels are 1 to 16 \(got 0\) \(channels count from 1/)
    expect { MB::Sound.midi_out(log: true, channel: 17) }.to raise_error(ArgumentError, /1 to 16/)
    expect { MB::Sound.midi_out(log: true, program: 0) }.to raise_error(ArgumentError, /programs count from 1/)
    expect { MB::Sound.midi_out(log: true, bank: [0, 200]) }.to raise_error(ArgumentError, /bank:/)
    expect { MB::Sound.midi_out }.to raise_error(ArgumentError, /Give midi_out a destination/)
    expect(MB::Sound.midi_out(log: true, channel: 10, program: 12, bank: [0, 3], offset: 4.ms).to_ruby)
      .to eq('midi_out(channel: 10, program: 12, bank: [0, 3], offset: 4.ms, log: true)')
  end

  it 'sends program, bank, and notes on their exact frames, the same at any buffer size' do
    logs = [800, 367, 128, 1].map { |size|
      size_frames = size == 1 ? 30_000 : 200_000
      s = session_at(size)
      d = MB::Sound.midi_out(log: true, channel: 2, program: 5, bank: [0, 3])
      s.arrangement.track(:k, d)
      s.arrangement.play(:k, riff, start_time: 0)
      run(s, size_frames, size)
      d.log.select { |f, _| f < 30_000 }
    }
    expect(logs[0][0, 4]).to eq([[0, [0xb1, 0, 0]], [0, [0xb1, 32, 3]], [0, [0xc1, 4]], [0, [0x91, 48, 95]]])
    expect(logs[0].map(&:first)).to eq([0, 0, 0, 0, 24000, 24000])
    expect(logs[0][4..].map(&:last)).to eq([[0x81, 48, 64], [0x91, 52, 95]])
    logs[1..].each { |l| expect(l).to eq(logs[0]) }
  end

  it 'adds the offset to every frame' do
    s = session_at(800)
    d = MB::Sound.midi_out(log: true, offset: 10.ms)
    s.arrangement.track(:k, d)
    s.arrangement.play(:k, riff, start_time: 0)
    run(s, 30_000, 800)
    expect(d.log.map(&:first)).to eq([480, 24480, 24480])
  end

  it 'ends held notes on the frame a mute or a cut stop stops the reading, at any buffer size' do
    results = [800, 367].map { |size|
      s = session_at(size)
      d = MB::Sound.midi_out(log: true)
      s.arrangement.track(:k, d)
      s.arrangement.play(:k, riff, start_time: 0)
      run(s, 10_000, size)
      s.mute(:k)
      run(s, 40_000, size)
      s.unmute(:k)
      run(s, 60_000, size)
      s.remove(:k, fade: 0)
      run(s, 40_000, size)
      d.log
    }
    expect(results[1]).to eq(results[0])
    log = results[0]
    # note-on C3 at 0; the mute (5 ms declick, 240 frames) ends it; no
    # notes while muted; after the unmute the next note plays on its frame
    # (no retrigger of a note in progress); the cut stop ends it
    expect(log[0]).to eq([0, [0x90, 48, 95]])
    mute_frame = results[0][1][0]
    expect(log[1]).to eq([mute_frame, [0x80, 48, 0]])
    on_frames = log.select { |_, b| b[0] == 0x90 }.map(&:first)
    expect(mute_frame).to eq(10_240) # (the mute lands at 10000, its 240-frame declick ends there)
    expect(on_frames).to eq([0, 96_000])
    last = log.last
    expect(last[1][0]).to eq(0x80)
    expect(log.count { |_, b| b[0] == 0x90 }).to eq(log.count { |_, b| b[0] == 0x80 })
  end

  # Runs a session at +size+ with a MIDI out track playing riff from frame
  # 0, calling the block with the session after +before+ frames, then runs
  # +after+ more.  Returns the destination's log.
  def scenario(size, before:, after:, **dest_opts)
    s = session_at(size)
    d = MB::Sound.midi_out(log: true, **dest_opts)
    s.arrangement.track(:k, d)
    s.arrangement.play(:k, riff, start_time: 0)
    run(s, before, size)
    yield s, d
    run(s, after, size)
    d.log
  end

  def balanced?(log)
    held = Hash.new(0)
    log.each { |_, b| held[b[1]] += 1 if b[0] & 0xf0 == 0x90; held[b[1]] -= 1 if b[0] & 0xf0 == 0x80 }
    held.values.all?(&:zero?)
  end

  it "sends the track's level as CC 7 once it has one" do
    logs = [800, 367].map { |size|
      scenario(size, before: 12_000, after: 20_000) { |s, _| s.level(:k, -6.db) }
    }
    expect(logs[1]).to eq(logs[0])
    cc7 = logs[0].select { |_, b| b[0] == 0xb0 && b[1] == 7 }
    expect(cc7.map { |_, b| b[2] }.uniq).to eq([(127 * Math.sqrt(-6.db.to_f)).round])
    expect(logs[0].first(1)).to eq([[0, [0x90, 48, 95]]]) # (no CC 7 before a level is set)
  end

  it 'ends notes on the swap frame, the pause frame, and leaves none held after a stop' do
    other = MB::Sound.seq(MB::Sound::A2).n2.loop
    swaps = [800, 367].map { |size|
      scenario(size, before: 10_000, after: 120_000) { |s, _| s.swap(:k, other, start_time: 5/8r) }
    }
    expect(swaps[1]).to eq(swaps[0])
    # G3 (48000..72000) ends on the swap's frame, the new clip plays on
    expect(swaps[0].last(2)).to eq([[60_000, [0x80, 55, 64]], [96_000, [0x90, 45, 95]]])

    pauses = [800, 367].map { |size|
      scenario(size, before: 30_000, after: 30_000) { |s, _| s.pause_transport }
    }
    expect(pauses[1]).to eq(pauses[0])
    # E3 started at 24000; the pause lands at 30000 and ends it there
    expect(pauses[0].last).to eq([30_000, [0x80, 52, 64]])
    expect(balanced?(pauses[0])).to eq(true)

    stop = scenario(800, before: 30_000, after: 2400) { |s, _| s.remove(:k, fade: 0) }
    expect(balanced?(stop)).to eq(true)
  end

  it 'sends all notes off on a panic' do
    log = scenario(800, before: 30_000, after: 2400) { |s, _| MB::Sound::MIDI::Destination.panic_all; s.remove(:k, fade: 0) }
    expect(log).to include([nil, [0xb0, 123, 0]], [nil, [0xb0, 120, 0]])
    expect(log.select { |f, b| f.nil? && b[0] == 0x80 }.map { |_, b| b[1] }).to eq([52]) # (E3 was sounding)
  end

  it 'plays an armed track\'s live input to the destination at once (not timed), in order' do
    s = session_at(800)
    ev = MB::Sound::MIDI::Event
    events = [[60, 1/10r, 3/10r], [64, 2/10r, 4/10r]].flat_map { |n, on, off| [ev.parse([0x90, n, 100], time: on), ev.parse([0x80, n, 64], time: off)] }
    s.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events.sort_by(&:time)))
    d = MB::Sound.midi_out(log: true, channel: 4)
    MB::Sound::Session.with_context(session: s) do
      s.arrangement.track(:hw, d)
      MB::Sound.arm(:hw)
    end
    run(s, 48_000, 800)
    expect(d.log).to eq([[nil, [0x93, 60, 100]], [nil, [0x93, 64, 100]], [nil, [0x83, 60, 64]], [nil, [0x83, 64, 64]]])
  end

  it 'sends a bound knob as its controller when it turns, on the frame it lands, at any buffer size' do
    expect { MB::Sound.midi_out(log: true, cc: { cut: 200 }) }.to raise_error(ArgumentError, /cc: binds knobs to controllers/)
    expect(MB::Sound.midi_out(log: true, cc: { cut: 74 }).to_ruby).to eq('midi_out(cc: { cut: 74 }, log: true)')
    logs = [800, 367].map { |size|
      s = session_at(size)
      s.knob(:cut, 1000, range: 100..10_000, curve: :exp)
      d = MB::Sound.midi_out(log: true, cc: { cut: 74 })
      s.arrangement.track(:k, d)
      s.arrangement.play(:k, riff, start_time: 0)
      run(s, 12_000, size)
      s.turn(:cut, 10_000, smooth: 0)
      run(s, 12_000, size)
      d.log.select { |_, b| b[0] == 0xb0 }
    }
    expect(logs[1]).to eq(logs[0])
    expect(logs[0].first).to eq([0, [0xb0, 74, 64]]) # (1000 is halfway along 100..10000 on an exponential curve)
    expect(logs[0].last[1]).to eq([0xb0, 74, 127])
    expect(logs[0].last[0]).to be_between(12_000, 12_000 + 480)
  end

  it 'refuses effect inserts on a MIDI out track' do
    s = session_at(800)
    s.arrangement.track(:k, MB::Sound.midi_out(log: true))
    expect { s.arrangement.fx(:k, :hall) }.to raise_error(MB::Sound::Arrangement::Fx::Error, /plays a MIDI destination: its sound is the synth's/)
    expect { s.arrangement.track(:k, MB::Sound.midi_out(log: true), fx: :hall) }.to raise_error(ArgumentError, /plays a MIDI destination/)
  end
end
