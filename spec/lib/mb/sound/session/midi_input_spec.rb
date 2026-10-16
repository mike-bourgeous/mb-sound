RSpec.describe(MB::Sound::Session::MidiInput) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  let(:ev) { MB::Sound::MIDI::Event }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # A stand-in for live input: events at stream times in seconds.
  def keyboard(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
  end

  def notes_at(*times)
    times.each_with_index.flat_map { |t, i| [ev.parse([0x90, 60 + i, 100], time: t.to_r), ev.parse([0x80, 60 + i, 64], time: t.to_r + 1/10r)] }
  end

  # Renders +frames+ frames in buffers of +sizes+ (cycled), returning the
  # first channel.
  def render(session, frames, sizes)
    out = []
    left = frames
    sizes.cycle do |n|
      break if left <= 0
      n = [n, left].min
      out << session.process_buffer(n)[0].dup
      left -= n
    end
    out.reduce(:concatenate)
  end

  # Frame indices where +data+ changes.
  def edges(data)
    d = data.to_a
    (1...d.length).select { |i| d[i] != d[i - 1] }
  end

  MIDI_INPUT_SIZES = [[800], [367, 368], [64], [1001, 13]].freeze

  it 'puts every event on the frame of its time and the position of that frame, at any buffer size' do
    times = [0.01r, 0.5r, 1/3r, 1.2345r]
    stamps = MIDI_INPUT_SIZES.map { |sizes|
      s = new_session
      s.add(0.constant, name: :clock, on: :now)
      input = s.midi_in
      input.input = keyboard(*notes_at(*times))
      seen = []
      s.add_tap { seen.concat(input.span.events) if input.span }
      render(s, 96000, sizes)
      seen.map { |st| [st.frame, st.pos, st.event.type, st.event.note] }
    }

    expected = (times.each_with_index.flat_map { |t, i| [[(t * 48000).floor, :note_on, 60 + i], [((t + 1/10r) * 48000).floor, :note_off, 60 + i]] }).sort_by(&:first)
    stamps.each do |list|
      expect(list.map { |f, _, type, note| [f, type, note] }).to eq(expected)
      list.each { |f, pos, _, _| expect(pos).to eq(Rational(f, 96000)) }
    end
  end

  it 'gives graphs reading its streams the events on the same frames, starting partway through a buffer' do
    results = MIDI_INPUT_SIZES.map { |sizes|
      s = new_session
      s.midi_in.input = keyboard(*notes_at(0.25r, 0.3r, 0.7r))
      s.add(MB::Sound::Notes.new(s.midi_in.stream).gate, name: :keys, on: :now)
      s.add(MB::Sound::Notes.new(s.midi_in.stream).number, name: :late, start_time: 1/4r) # starts on frame 24000 (0.5 s)
      render(s, 48000, sizes)
    }

    results.each { |d| expect(d).to eq(results[0]) }
    d = results[0]
    expect(edges(d)).to eq([12000, 19200, 24000, 33600, 38400])
    # :late starts at 0.5 s (its number is 60 until a note), then hears only note 62
    expect([d[12000], d[24000], d[33600], d[38400]]).to eq([1, 60, 63, 62])
  end

  it 'gives graphs reading a span in pieces the events on their frames (a Synth split at its grid points)' do
    # fixes-7: a span's events were placed as if the first read covered
    # the end of the span, so a Synth starting off its grid (reading the
    # span in two pieces) heard them early or not at all
    results = MIDI_INPUT_SIZES.map { |sizes|
      s = new_session
      s.midi_in.input = keyboard(*notes_at(0.3r, 0.41r, 0.7r))
      syn = MB::Sound::Synth.new(s.midi_in.stream, voices: 2) { |v| v.gate }
      s.add(syn, name: :keys, start_time: 1/7r) # frame 13714, off the 800 grid
      render(s, 48000, sizes)
    }

    results.each { |d| expect(d).to eq(results[0]) }
    expect(edges(results[0])).to eq([14400, 19200, 19680, 24480, 33600, 38400])
  end

  it 'leaves out events from before a graph started reading' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    s.midi_in.input = keyboard(*notes_at(0.01r))
    render(s, 4800, [800])
    s.add(MB::Sound::Notes.new(s.midi_in.stream).gate, name: :keys, on: :now)
    d = render(s, 9600, [800])
    expect(d.max).to eq(0)
  end

  it 'keeps a history of recent events by timeline position' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    s.midi_in.input = keyboard(*notes_at(0.5r, 1r))
    render(s, 96000, [800])
    h = s.midi_in.history(0, 1)
    expect(h.map { |pos, e| [pos, e.type] }).to eq([[1/4r, :note_on], [1/4r + 1/20r, :note_off], [1/2r, :note_on], [1/2r + 1/20r, :note_off]])
    expect(s.midi_in.history(1/2r, 1).length).to eq(2)
  end

  it 'journals each controller gesture once it stops, naming the knob it moved' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    k = s.knob(:cut, 0.5, smooth: 0, takeover: :jump)
    s.bind_cc(:cut, 74)
    sweep = (0..10).map { |i| ev.cc_raw(74, 10 * i, time: Rational(i, 100)) }
    wheel = [ev.cc_raw(1, 5, time: 1r), ev.cc_raw(1, 9, time: 1.02r)]
    s.midi_in.input = keyboard(*sweep, *wheel)
    render(s, 96000 * 2, [800])

    entries = s.journal.changes.select { |e| e.kind == :cc }
    expect(entries.map(&:subject)).to eq([:cut, :cc1])
    expect(entries[0].source).to eq(:midi)
    expect(entries[0].data).to include(control: 74, from: 0, to: 100, moves: 11, knobs: [:cut])
    expect(entries[0].lands.frame).to eq(0)
    expect(entries[1].lands.pos).to eq(1/2r)
    expect(k.value).to be_within(1e-6).of(100 / 127.0)
  end

  it 'moves knobs listening to it on exact frames at any buffer size' do
    results = MIDI_INPUT_SIZES.map { |sizes|
      s = new_session
      k = s.knob(:x, 0.5, smooth: 0, takeover: :jump)
      s.bind_cc(:x, 20)
      s.midi_in.input = keyboard(ev.cc_raw(20, 13, time: 0.0101r), ev.cc_raw(20, 100, time: 0.0789r))
      s.add(k * 1, name: :x, on: :now)
      render(s, 9600, sizes)
    }
    results.each { |d| expect(d).to eq(results[0]) }
    expect(edges(results[0])).to eq([(0.0101 * 48000).floor, (0.0789 * 48000).floor])
  end

  it 'replays recorded rows on the frames of their positions' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    s.midi_in.input = keyboard(*notes_at(0.25r, 0.3r))
    s.add(MB::Sound::Notes.new(s.midi_in.stream).gate, name: :keys, on: :now)
    live = render(s, 48000, [800])
    rows = s.midi_log.map { |_, epoch, pos, bytes| [epoch, pos, bytes] }
    expect(rows.length).to eq(4)

    MIDI_INPUT_SIZES.each do |sizes|
      r = new_session
      r.replay_midi!
      r.midi_in.replay(rows)
      r.add(0.constant, name: :clock, on: :now)
      r.add(MB::Sound::Notes.new(r.midi_in.stream).gate, name: :keys, on: :now)
      expect(render(r, 48000, sizes)).to eq(live)
    end
  end

  it 'merges added sources (a virtual keyboard beside the input) into each span in time order' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    input = s.midi_in
    input.input = keyboard(*notes_at(0.1r))
    extra = input.add_source(keyboard(ev.parse([0x90, 72, 90], time: 0.05r), ev.parse([0x80, 72, 0], time: 0.2r)))
    expect(input.sources).to eq([extra])
    seen = []
    s.add_tap { seen.concat(input.span.events) if input.span }
    render(s, 24000, [367, 368])
    expect(seen.map { |st| [st.frame, st.event.type, st.event.note] }).to eq([
      [2400, :note_on, 72], [4800, :note_on, 60], [9600, :note_off, 60], [9600, :note_off, 72], # the input's first
    ])
    # The MIDI log (what takes replay) has both
    expect(s.midi_log.map { |row| row[3][1] }).to eq([72, 60, 60, 72])

    input.remove_source(extra)
    expect(input.sources).to eq([])
  end

  it 'reads a MIDI::VirtualInput through a LiveSource, keeping the time between messages' do
    s = new_session
    s.add(0.constant, name: :clock, on: :now)
    t = 10.0
    vin = MB::Sound::MIDI::VirtualInput.new(clock: -> { t })
    s.midi_in.add_source(MB::Sound::MIDI::LiveSource.new(vin, latency: 0.02))
    seen = []
    s.add_tap { seen.concat(s.midi_in.span.events) if s.midi_in.span }
    # The clock moves with the rendered frames, as a realtime Session's does
    40.times do |i|
      vin.note_on(60, 0.5) if i == 2
      vin.note_off(60) if i == 17 # 0.25 s later
      render(s, 800, [800])
      t += 800 / 48000r
    end
    on, off = seen
    expect(on.event.note).to eq(60)
    expect(on.event.velocity).to be_within(0.01).of(0.5)
    expect(off.frame - on.frame).to eq(12000)
    expect(vin.pending).to eq(0)
  end
end
