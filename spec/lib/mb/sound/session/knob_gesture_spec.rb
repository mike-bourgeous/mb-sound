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
        before = SpecBuffers.join(out)
        expect(session.journal.changes.count { |e| e.kind == :turn }).to eq(0)
        code = session.gesture_line(:g)
        expect(code).to eq('turn :g, 0 => 0.32, (1/60r).seconds => 0.36, (1/30r).seconds => 0.38, (1/6r).seconds => 0.5') # (one unit per line: a key off the grid prints them all in seconds)
        line.(code)
      end
      out << session.process_buffer[0].dup
    end
    [SpecBuffers.join(out), t, before]
  end

  def replay(r, sizes)
    out = []
    r.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| out << mix[0].dup }
    SpecBuffers.join(out)
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

  # A track's level gesture (the tracks pane's held Left/Right;
  # knobs-pane-keys-1 round 2, the maintainer's 2026-11-21 "one `level`
  # line on release"): the same gesture on the level knob, printed as its
  # final value, `level :x, -6.02.db`.
  describe 'on a track level' do
    def level_perform
      b = MB::Sound::Take.console_binding
      t = MB::Sound::Take.new(session: session)
      line = ->(code) { MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      line.('track :x, 1.constant')
      line.('go_x = scene(:a, x: :on)')
      line.('go :a, on: :now')
      out = []
      before = nil
      steps = { 20 => [-1.db.to_f], 21 => [-2.db.to_f, -3.db.to_f], 22 => [-4.db.to_f], 30 => [0.5] }
      60.times do |i|
        steps.fetch(i, []).each { |v| session.preview_turn(:"x/level", v) }
        if i == 45
          before = SpecBuffers.join(out)
          expect(session.journal.changes.count { |e| e.kind == :turn }).to eq(0)
          code = session.gesture_line(:"x/level")
          expect(code).to eq('level :x, -6.02.db') # (0.5 is -6.0206 dB: the line's -6.02.db is 0.49998, still this gesture's)
          line.(code)
        end
        out << session.process_buffer[0].dup
      end
      [SpecBuffers.join(out), t, before]
    end

    it 'moves the level while held, then one level line: one journal entry, replayed bit for bit at two buffer sizes' do
      live, take, before = level_perform
      expect(before[20 * 800 - 1]).to be_within(1e-6).of(1.0)
      expect(before[23 * 800 - 1]).to be_within(1e-4).of(-4.db.to_f)
      expect(before[40 * 800]).to be_within(1e-6).of(0.5)
      turns = session.journal.changes.select { |e| e.kind == :turn }
      expect(turns.length).to eq(1)
      expect(turns[0].subject).to eq(:"x/level")
      expect(turns[0].data).to include(gesture: true)
      expect(turns[0].data[:raw].map(&:last)).to eq([-1.db, -3.db, -4.db, 0.5].map { |v| Float(MB::Sound::GraphNode::Knob.number(v.to_f)) })
      expect(take.lines.last.code).to eq('level :x, -6.02.db')
      expect(take.lines.last.lands).to eq([20 * 800 / 96000r])
      expect(session.knob_gestures).to eq({})
      [[800], [367, 368]].each do |sizes|
        rep = replay(take.replay, sizes)
        n = [rep.length, live.length].min
        expect(n).to be > 50 * 800
        expect(rep[0...n] == live[0...n]).to eq(true), "replay at #{sizes.inspect} differs from the live render"
      end
    end

    it 'undoes the whole gesture in one step, back to the level from before it' do
      level_perform
      MB::Sound::Session.with_context(session: session) { session.undo(on: :now) }
      3.times { session.process_buffer }
      expect(session.knobs[:"x/level"].value).to be_within(1e-9).of(1.0)
    end

    it 'prints the final value in dB as level gives it, and takes that line as the gesture at the rounding edges' do
      MB::Sound::Session.with_context(session: session) { MB::Sound.track(:x, 1.constant) }
      run = ->(code) { MB::Sound::Session.with_context(session: session) { eval(code, MB::Sound::Take.console_binding) } } # rubocop:disable Security/Eval
      {
        -10.db.to_f => 'level :x, -10.0.db', # (previewed as 0.3162, -10.0004 dB)
        0.5 => 'level :x, -6.02.db', # (the line's gain differs from the step's)
        1.0 => 'level :x, 0.0.db',
        0.0 => 'level :x, (-Float::INFINITY).db',
        4.0 => 'level :x, 12.04.db', # (MAX_LEVEL)
      }.each do |gain, want|
        session.preview_turn(:"x/level", 0.7)
        session.preview_turn(:"x/level", gain)
        3.times { session.process_buffer }
        code = session.gesture_line(:"x/level")
        expect(code).to eq(want)
        run.(code)
        expect(session.journal.changes.last.data).to include(gesture: true)
        expect(session.knob_gestures).to eq({}), "#{want}: not taken as the gesture's line"
      end
      # (a plain level at another value while no gesture is live: a turn of its own)
      run.('level :x, -3.db')
      expect(session.journal.changes.last.data).not_to include(:gesture)
    end
  end
end
