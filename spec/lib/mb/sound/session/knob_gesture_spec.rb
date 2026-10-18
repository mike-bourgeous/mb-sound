# Held-key knob gestures (ux-r4b item 3, maintainer 2026-10-18): a held
# arrow in the racks pane moves the knob live (Session#preview_turn, no
# journal entry), then the gesture becomes one console line
# (Session#gesture_line: its fitted keyframes, gesture-curves) journaled at
# its first step: one journal entry, one undo step, one take line, and the
# take replays what was heard (the raw steps it keeps).
RSpec.describe('Session knob gestures', :aggregate_failures) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) {
    MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: transport,
                           channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
  }

  after { session.close }

  # Plays: a knob into the mix, then a held gesture (steps at buffers
  # 20, 21, 22, 30: two in one span merge), committed at buffer 45.
  # Returns [mix (left), take, values heard before the commit].
  def perform
    b = MB::Sound::Take.console_binding
    t = MB::Sound::Take.new(session: session)
    line = ->(code) { MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
    line.('knob :g, 0.3')
    line.('bg :x, knob(:g) * 1')
    out = []
    before = nil
    steps = { 20 => [0.32], 21 => [0.34, 0.36], 22 => [0.38], 30 => [0.5] }
    60.times do |i|
      steps.fetch(i, []).each { |v| session.preview_turn(:g, v) }
      if i == 45
        before = out.reduce(:concatenate)
        expect(session.journal.changes.count { |e| e.kind == :turn }).to eq(0)
        code = session.gesture_line(:g)
        expect(code).to eq('turn :g, 0 => 0.32, (1r/60).seconds => 0.36, (1r/30).seconds => 0.38, (1r/6).seconds => 0.5') # (one unit per line: a key off the grid prints them all in seconds)
        line.(code)
      end
      out << session.process_buffer[0].dup
    end
    [out.reduce(:concatenate), t, before]
  end

  def replay(r, sizes)
    out = []
    r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
    out.reduce(:concatenate)
  end

  it 'moves the knob in the audio while held, journals one turn at its first step, and replays bit for bit at two buffer sizes' do
    live, take, before = perform
    # Heard while held, before any journal entry
    expect(before[20 * 800 - 1]).to be_within(1e-6).of(0.3)
    expect(before[21 * 800 - 1]).to be_within(1e-6).of(0.32)
    expect(before[23 * 800 - 1]).to be_within(1e-6).of(0.38)
    expect(before[40 * 800]).to be_within(1e-6).of(0.5)
    # One journal entry, one take line landing at the gesture's first step
    turns = session.journal.changes.select { |e| e.kind == :turn }
    expect(turns.length).to eq(1)
    expect(turns[0].data).to include(gesture: true, value: 0.5, raw: [[0, 0.32], [800, 0.36], [1600, 0.38], [8000, 0.5]])
    expect(take.gestures).to eq([[:g, 0, 20 * 800 / 96000r, [[0, 0.32], [800, 0.36], [1600, 0.38], [8000, 0.5]]]])
    expect(take.lines.last.lands).to eq([20 * 800 / 96000r])
    expect(session.knob_gestures).to eq({})
    # Replays: the same samples
    ref = live
    [[800], [367, 368]].each do |sizes|
      rep = replay(take.replay, sizes)
      n = [rep.length, ref.length].min
      expect(n).to be > 50 * 800
      expect(rep[0...n] == ref[0...n]).to eq(true), "replay at #{sizes.inspect} differs from the live render"
    end
  end

  it 'undoes a gesture in one step, back to the value from before it' do
    perform
    MB::Sound::Session.with_context(session: session) { session.undo(on: :now) }
    3.times { session.process_buffer }
    expect(session.knobs[:g].value).to be_within(1e-9).of(0.3)
  end

  it 'writes a one-step gesture as a plain turn, and plays steps from where a turn lands when no gesture is live' do
    MB::Sound::Session.with_context(session: session) { session.knob(:h, 0.1) }
    session.preview_turn(:h, 0.25)
    expect(session.gesture_line(:h)).to eq('turn :h, 0.25')
    MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:h, 0.25) }
    expect(session.knob_gestures).to eq({})
    expect(session.journal.changes.last.data).to include(gesture: true)
    MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:h, 0 => 0.5, 1600.samples => 0.7) }
    expect(session.journal.changes.last.data).not_to include(:gesture)
    4.times { session.process_buffer }
    expect(session.knobs[:h].value).to be_within(1e-9).of(0.7)
    expect { MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:h, 0.5, 0 => 0.6) } }.to raise_error(ArgumentError, /keyframes .* or a value, not both/)
    expect { MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:h, 0 => 0.6, ovr: 2) } }.to raise_error(ArgumentError, /unknown keyword: :ovr.*did you mean over/)
    expect { MB::Sound::Session.with_context(session: session) { MB::Sound.turn(:h, 0 => 0.6, 0.samples => 0.7) } }.to raise_error(ArgumentError, /Two gesture keys land on frame 0/)
  end
end
