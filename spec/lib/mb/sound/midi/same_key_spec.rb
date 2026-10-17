# Overlapping notes on one key from real-time input (+same_key: :restrike+):
# a keyboard that dropped a note-off (jack-keyboard losing focus with a key
# down) is fixed by pressing the key again.  The Allocator's own cases are in
# allocator_spec.rb ('same_key').
RSpec.describe('same_key: :restrike') do
  let(:ev) { MB::Sound::MIDI::Event }

  # Events 10 ms (480 samples) apart in the order given.
  def timeline(*events)
    events.each_with_index.map { |e, idx| e.at(Rational(idx, 100)) }
  end

  def live_stream(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(timeline(*events), realtime: true))
  end

  def file_stream(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(timeline(*events)))
  end

  def on(n, ch: 0) = ev.note_on(n, 1.0, channel: ch)
  def off(n, ch: 0) = ev.note_off(n, channel: ch)

  # The gate's value just before each 10 ms step ends (0 once it ended).
  def gate_steps(notes, steps)
    g = notes.gate
    steps.times.map { g.sample(480)&.[](-1) || 0 }
  end

  describe MB::Sound::MIDI::Source do
    it 'is real-time input for live sources and a Session MIDI input, not for files and clips' do
      input = Class.new {
        def read_raw = []
        def frame_times? = false
        def frame_rate = nil
        def close; end
        def closed? = false
      }.new
      expect(MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::LiveSource.new(input, timing: :asap)).realtime_input?).to eq(true)
      expect(file_stream(on(60)).realtime_input?).to eq(false)
      expect(MB::Sound::MIDI::Stream.for(MB::Sound.seq(MB::Sound::C4)).realtime_input?).to eq(false)

      session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: 800, sleep: false), realtime: false)
      begin
        expect(session.midi_in.stream.realtime_input?).to eq(true)
        expect(session.midi_in.stream.sustain.realtime_input?).to eq(true)
      ensure
        session.close
      end
    end

    it 'is not real-time input for Allocator lanes (overlaps are already settled)' do
      a = MB::Sound::MIDI::Allocator.new(live_stream(on(60)), voices: 2)
      expect(a.lanes[0].realtime_input?).to eq(false)
    end
  end

  describe MB::Sound::MIDI::Stream, '#restrike' do
    def read(stream, seconds = 1)
      stream.reader.next(seconds).map { |e| "#{e.type == :note_on ? 'on' : e.type == :note_off ? 'off' : e.type}#{e.note}@#{(e.time * 100).round}" }
    end

    it 'ends a held note before a note-on for its key and drops the older note-off' do
      expect(read(file_stream(on(60), on(60), off(60), off(60)).restrike)).to eq(['on60@0', 'off60@1', 'on60@1', 'off60@2'])
    end

    it 'leaves balanced notes and other events alone' do
      s = file_stream(on(60), ev.cc(1, 0.5), on(64), off(60), off(64))
      expect(read(s.restrike)).to eq(read(file_stream(on(60), ev.cc(1, 0.5), on(64), off(60), off(64))))
    end

    it 'keeps channels apart and forgets a channel at all notes off' do
      s = file_stream(on(60), on(60, ch: 1), ev.cc(123, 0), on(60), off(60), off(60, ch: 1))
      expect(read(s.restrike)).to eq(['on60@0', 'on60@1', 'cc123@2', 'on60@3', 'off60@4', 'off60@5'])
    end
  end

  describe MB::Sound::Notes do
    it 'defaults to :restrike on real-time input, :count otherwise' do
      expect(gate_steps(MB::Sound::Notes.new(live_stream(on(60), on(60), off(60))), 4)).to eq([1, 1, 0, 0])
      expect(gate_steps(MB::Sound::Notes.new(file_stream(on(60), on(60), off(60))), 4)).to eq([1, 1, 1, 1])
    end

    it 'takes same_key: either way' do
      expect(gate_steps(MB::Sound::Notes.new(file_stream(on(60), on(60), off(60)), same_key: :restrike), 4)).to eq([1, 1, 0, 0])
      expect(gate_steps(MB::Sound::Notes.new(live_stream(on(60), on(60), off(60)), same_key: :count), 4)).to eq([1, 1, 1, 1])
      expect { MB::Sound::Notes.new(file_stream, same_key: :maybe) }.to raise_error(ArgumentError, /same_key/)
    end

    it 'restrikes under the sustain pedal too (the pedal lift ends the note)' do
      n = MB::Sound::Notes.new(live_stream(on(60), ev.cc(64, 1), on(60), off(60), ev.cc(64, 0)))
      expect(gate_steps(n, 6)).to eq([1, 1, 1, 1, 0, 0])
    end

    it 'fires a trigger at the re-press' do
      n = MB::Sound::Notes.new(live_stream(on(60), on(60), off(60)))
      t = n.trigger
      hits = 3.times.map { t.sample(480).to_a.count(&:positive?) }
      expect(hits).to eq([1, 1, 0])
    end
  end

  describe MB::Sound::Synth do
    def synth(stream, **opts)
      MB::Sound::Synth.new(stream, voices: 4, spares: 0, skip_idle: false, **opts) { |v| v.gate * 1 }
    end

    it 'releases a re-pressed live key at its next note-off (every retrigger preset)' do
      MB::Sound::Synth::RETRIGGER_MODES.each do |mode|
        s = synth(live_stream(on(60), on(60), off(60)), retrigger: mode)
        expect(s.same_key).to eq(:restrike)
        out = 4.times.map { s.sample(480)[-1] }
        expect(out).to eq([1, 1, 0, 0]), "retrigger #{mode}: #{out}"
      end
    end

    it 'keeps counting for files and clips' do
      s = synth(file_stream(on(60), on(60), off(60)))
      expect(s.same_key).to eq(:count)
      expect(4.times.map { s.sample(480)[-1] }).to eq([1, 2, 1, 1])
    end

    it 'restarts the same lane, landing on the exact sample at any buffer size' do
      ref = nil
      [480, 7, 128, 800].each do |size|
        s = MB::Sound::Synth.new(live_stream(on(60), on(60), off(60)), voices: 4, spares: 0, skip_idle: false) { |v| v.gate * (v.number * 0 + 1) }
        out = []
        out.concat(s.sample(size).to_a) while out.length < 2000
        out = out.first(2000)
        ref ||= out
        expect(out).to eq(ref)
        expect(out.index(0.0)).to eq(960)
      end
    end

    it 'follows the Notes it was made from' do
      n = MB::Sound::Notes.new(live_stream(on(60)), same_key: :count)
      expect(n.synth { |v| v.gate }.same_key).to eq(:count)
      expect(MB::Sound::Notes.new(live_stream(on(60))).synth { |v| v.gate }.same_key).to eq(:restrike)
    end
  end

  describe MB::Sound::MIDI::Output::NoteBalancer do
    def run(*messages)
      b = MB::Sound::MIDI::Output::NoteBalancer.new
      messages.flat_map { |m| b.filter(m.pack('C*')) }.map(&:bytes)
    end

    it 'ends a held note before a note-on for its key, and drops the extra note-off' do
      expect(run([0x90, 60, 100], [0x90, 60, 90], [0x80, 60, 0], [0x80, 60, 0])).to eq(
        [[0x90, 60, 100], [0x80, 60, 0], [0x90, 60, 90], [0x80, 60, 0]]
      )
    end

    it 'treats note-on velocity 0 as a note-off and keeps channels apart' do
      expect(run([0x90, 60, 100], [0x91, 60, 100], [0x90, 60, 0], [0x81, 60, 64])).to eq(
        [[0x90, 60, 100], [0x91, 60, 100], [0x90, 60, 0], [0x81, 60, 64]]
      )
    end

    it 'passes other messages and forgets a channel at all notes off' do
      expect(run([0x90, 60, 100], [0xB0, 123, 0], [0x90, 60, 100], [0xE0, 0, 64], [0xA0, 60, 10], [0xF8])).to eq(
        [[0x90, 60, 100], [0xB0, 123, 0], [0x90, 60, 100], [0xE0, 0, 64], [0xA0, 60, 10], [0xF8]]
      )
    end
  end
end
