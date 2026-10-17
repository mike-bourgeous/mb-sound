# Live scripts' panic keys and MIDI diagnostics (ux-1 item 19).
RSpec.describe(MB::Sound::ScriptRunner::LiveKeys, :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }
  let(:out) { StringIO.new }
  let(:t) { [0.0] }
  let(:keys) { described_class.new(session, out: out, clock: -> { t[0] }, log: true, stuck: '5') }

  after { session.close }

  it 'sends all notes off on Esc and all sound off on a second Esc, which release a held synth voice' do
    ev = MB::Sound::MIDI::Event
    session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.parse([0x90, 60, 100], time: 0.01r)))
    synth = MB::Sound::Synth.new(session.midi_in.stream, voices: 1) { |v| v.hz.sine * v.amp_env(0.001, 0.01, 1, 0.01) }
    session.add(synth, name: :s, at: :now)
    20.times { session.process_buffer }
    expect(session.process_buffer[0].abs.max).to be > 0.1 # held
    expect(keys.key("\e")).to eq(:panic)
    t[0] = 0.5
    expect(keys.key("\e")).to eq(:sound_off)
    20.times { session.process_buffer }
    expect(session.process_buffer[0].abs.max).to eq(0) # released
    ccs = session.midi_log.map { |r| r[3] }.select { |b| b[0] & 0xF0 == 0xB0 }.map { |b| [b[0] & 0x0F, b[1]] }
    expect(ccs.count { |_, c| c == 123 }).to eq(32)
    expect(ccs.count { |_, c| c == 120 }).to eq(16)
    expect(out.string).to include('all notes off', 'all sound off')
    t[0] = 3.0
    expect(keys.key("\e")).to eq(:panic) # (a second later: notes off again)
    expect(keys.key('q')).to eq(:quit)
    expect(keys.key("\x03")).to eq(:quit)
  end

  it 'logs MIDI as it arrives (MIDI_LOG=1), lists recent events (l), and warns once about stuck notes (MIDI_STUCK)' do
    ev = MB::Sound::MIDI::Event
    session.midi_in.input = MB::Sound::MIDI::Stream.new(MIDIListSource.new(ev.parse([0x90, 60, 100], time: 0.01r), ev.parse([0x91, 64, 90], time: 0.02r), ev.parse([0x80, 60, 0], time: 0.05r)))
    session.add(0.constant, name: :c, at: :now)
    keys # (it reads what comes after it starts)
    10.times { session.process_buffer }
    keys.poll(0.0)
    expect(out.string).to include('ch 1 note on  C4 vel 100', 'ch 2 note on  E4 vel 90', 'ch 1 note off C4')
    keys.poll(6.0)
    keys.poll(7.0)
    expect(out.string.scan('note E4 on channel 2 held 6 s (stuck?').length).to eq(1)
    expect(out.string).not_to include('note C4 on channel 1 held')
    out.truncate(0)
    out.rewind
    expect(keys.key('l')).to eq(:log)
    expect(out.string.lines.length).to eq(3)
  end
end
