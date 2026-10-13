RSpec.describe(MB::Sound::RecordMethods) do
  # 120 BPM at 48kHz: one bar (a whole note, 2 s) is 96000 frames
  let(:ev) { MB::Sound::MIDI::Event }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def new_session
    transport = MB::Sound::Sequence::Transport.new(bpm: 120)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true).tap { |s| sessions << s }
  end

  # Notes played on a stand-in keyboard: [note, on seconds, off seconds].
  def keyboard(*notes)
    events = notes.flat_map { |n, on, off| [ev.parse([0x90, n, 100], time: on.to_r), ev.parse([0x80, n, 64], time: off.to_r)] }
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events))
  end

  # Plays +lines+ (buffer index => console lines) in buffers of +sizes+
  # (cycled; lines run before the buffer that starts at or after frame
  # 800 * index).  Returns the first channel.
  def perform(session, lines, frames, sizes = [800])
    b = MB::Sound::Take.console_binding
    pending = lines.sort.to_h
    out = []
    done = 0
    sizes.cycle do |n|
      break if done >= frames
      pending.keys.select { |i| i * 800 <= done }.each do |i|
        pending.delete(i).each { |code| MB::Sound::Session.with_context(session: session) { b.eval(code) } }
      end
      n = [n, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    out.reduce(:concatenate)
  end

  def setup_lead(session, monitor: false)
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.track(:lead, q: 1) { |c| c.number * c.gate }
    end
  end

  RECORDING_SIZES = [[800], [367, 368], [64], [1001, 13]].freeze
  RECORDING_PLAYED = [[60, 2.1r, 2.35r], [64, 2.6r, 2.9r], [67, 3.3r, 4.5r], [72, 3.99r, 4.2r]].freeze

  describe 'rec (MIDI looper)' do
    it 'records the next bars into an armed track, swapping the loop in on the frame where it closes, at any buffer size' do
      results = RECORDING_SIZES.map { |sizes|
        s = new_session
        s.midi_in.input = keyboard(*RECORDING_PLAYED)
        setup_lead(s)
        data = perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 10 => ['arm :lead, monitor: false', 'rec 1'] }, 96000 * 4, sizes)
        [data, s.arrangement.captures, s]
      }

      clips = results.map { |_, c, _| c[:lead_1] }
      clips.each { |c| expect(c.events.map { |e| [e.start, e.length, e.value] }).to eq(clips[0].events.map { |e| [e.start, e.length, e.value] }) }

      # Bar 2 is 2..4 s: notes start at exact positions within the loop;
      # the note held past the window ends with it, and the hair-early 72 is
      # the next loop's downbeat (left out)
      expect(clips[0].events.map { |e| [e.start, e.length, e.value] }).to eq([
        [1/20r, 1/8r, 60], [3/10r, 3/20r, 64], [13/20r, 1 - 1/64r - 13/20r, 67], # held past the window: ends where it closes
      ])
      expect(clips[0].looping?).to eq(true)
      expect(clips[0].length).to eq(1r)

      results.each { |d, _, _| expect(d).to eq(results[0][0]) }
      d = results[0][0]
      expect(d[0...192000].abs.max).to eq(0) # nothing on :lead until the loop closes
      expect(d[192000 + 4799]).to eq(0)
      expect(d[192000 + 4800]).to eq(60)      # 1/20 whole note into bar 3

      s = results[0][2]
      kinds = s.journal.changes.select { |e| e.subject == :lead }.map { |e| [e.kind, e.lands.to_s] }
      expect(kinds).to eq([[:arm, '1:1.333'], [:rec, '2:1'], [:bg, '3:1'], [:capture, '3:1']])
      expect(s.arrangement.tracks[:lead].clip).to equal(clips[0])
      expect(clips[0].name).to eq(:lead_1)
    end

    it 'swaps into a track that is already playing, keeping its graph' do
      s = new_session
      s.midi_in.input = keyboard(*RECORDING_PLAYED)
      setup_lead(s)
      first = MB::Sound.seq(MB::Sound::C3).n1.loop
      MB::Sound::Session.with_context(session: s) { MB::Sound.bg(:lead, first) }
      graph = s.instance_variable_get(:@players).values.last.input
      d = perform(s, { 10 => ['rec 1, :lead'] }, 96000 * 4)
      expect(s.instance_variable_get(:@players).values.find { |p| p.name == :lead }.input).to equal(graph)
      expect(d[96000 + 10]).to eq(48)            # still C3 in bar 2 while recording
      expect(d[192000 + 4800]).to eq(60)         # the recorded loop from bar 3
    end

    it 'quantizes and humanizes on request' do
      s = new_session
      s.midi_in.input = keyboard(*RECORDING_PLAYED)
      setup_lead(s)
      perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 10 => ['arm :lead, monitor: false', 'rec 1, quantize: 16'] }, 96000 * 3)
      expect(s.arrangement.captures[:lead_1].events.map(&:start)).to eq([1/16r, 5/16r, 5/8r])
    end

    it 'keeps the loop when its track was stopped before it closed (e.g. a render ending mid-take)' do
      s = new_session
      s.midi_in.input = keyboard(*RECORDING_PLAYED)
      setup_lead(s)
      d = perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 10 => ['arm :lead, monitor: false', 'rec 1'], 60 => ['stop :lead'] }, 96000 * 3)
      expect(s.arrangement.captures[:lead_1].events.length).to eq(3)
      expect(d.abs.max).to eq(0) # nothing to swap it into
    end

    it 'can be undone before it lands, and needs an armed or named track with a patch' do
      s = new_session
      s.midi_in.input = keyboard(*RECORDING_PLAYED)
      setup_lead(s)
      d = perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 10 => ['rec 1, :lead'], 20 => ['undo'] }, 96000 * 3)
      expect(d.abs.max).to eq(0)
      expect(s.arrangement.captures).to be_empty

      MB::Sound::Session.with_context(session: s) do
        expect { MB::Sound.rec(1) }.to raise_error(ArgumentError, /Arm a track/)
        MB::Sound.track(:pad, 0.constant)
        expect { MB::Sound.rec(1, :pad) }.to raise_error(ArgumentError, /patch/)
        expect { MB::Sound.rec(1, :nope) }.to raise_error(ArgumentError, /No track :nope/)
        expect { MB::Sound.rec(:lead) }.to raise_error(ArgumentError, /length in bars/)
        # Audio has its own command (omnibus6): rec alone or with a path is an error
        expect { MB::Sound.rec }.to raise_error(ArgumentError, /records MIDI.*use rec_audio$/)
        expect { MB::Sound.rec('x.flac') }.to raise_error(ArgumentError, /use rec_audio "x.flac"/)
        expect { MB::Sound.rec_audio(4) }.to raise_error(ArgumentError, /MIDI recording is rec 4/)
        expect(MB::Sound.respond_to?(:stop_rec)).to eq(false) # audio commands all say audio
      end
    end
  end

  describe 'capture' do
    it 'captures the last phrase into the track at its next launch point, playing on in phase' do
      s = new_session
      # A phrase in bars 3 and 4 (4..8 s); the note in bar 1 is more than a bar before it
      s.midi_in.input = keyboard([50, 0.0r, 0.1r], [60, 4.5r, 4.75r], [62, 5.5r, 5.75r], [64, 6.5r, 6.75r], [65, 7.5r, 7.75r])
      setup_lead(s)
      d = perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 400 => ['capture :lead'] }, 96000 * 6)
      clip = s.arrangement.captures[:lead_1]
      expect(clip.length).to eq(2r)
      expect(clip.events.map { |e| [e.start, e.length, e.value] }).to eq([[1/4r, 1/8r, 60], [3/4r, 1/8r, 62], [5/4r, 1/8r, 64], [7/4r, 1/8r, 65]])
      expect(s.journal.changes.find { |e| e.kind == :capture }.lands.to_s).to eq('5:1')
      expect(d[384000 - 1]).to eq(0)
      expect(d[384000 + 24000 - 1]).to eq(0)
      expect(d[384000 + 24000]).to eq(60) # bar 5 plays the loop's first bar, in phase
      expect(d[480000 + 24000]).to eq(64)
    end

    it 'takes a length in bars: the bars before the launch point' do
      s = new_session
      s.midi_in.input = keyboard(*RECORDING_PLAYED)
      setup_lead(s)
      perform(s, { 0 => ['bg :clock, 0.constant, on: :now'], 200 => ['capture :lead, 1'] }, 96000 * 4)
      clip = s.arrangement.captures[:lead_1]
      expect(clip.events.map { |e| [e.start, e.value] }).to eq([[1/20r, 60], [3/10r, 64], [13/20r, 67]])
    end

    it 'raises when nothing was played' do
      s = new_session
      s.midi_in.input = keyboard
      setup_lead(s)
      MB::Sound::Session.with_context(session: s) do
        expect { MB::Sound.capture(:lead) }.to raise_error(ArgumentError, /Nothing played/)
      end
    end
  end

  describe 'arm' do
    it "monitors live input through the track's patch, and disarm stops it" do
      s = new_session
      s.midi_in.input = keyboard([60, 0.5r, 0.75r], [62, 2.5r, 2.75r])
      setup_lead(s)
      d = perform(s, { 0 => ['arm :lead'], 40 => ['disarm :lead'] }, 96000 * 2)
      expect(s.players.keys).not_to include(:'lead/live')
      expect(d[24000 - 1]).to eq(0)
      expect(d[24000]).to eq(60)
      expect(d[120000]).to eq(0)
      expect(s.arrangement.armed).to be_empty
      expect(MB::Sound::Session.with_context(session: s) { MB::Sound.tracks[:lead] }).not_to include('armed')
    end

    it 'plays live input through patches that take any MIDI source (MB::Sound.synth, tr808)' do
      s = new_session
      s.midi_in.input = keyboard([60, 0.5r, 0.75r])
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:lead, q: 1) { |c| MB::Sound.synth(c, voices: 1) { |v| v.number * v.gate } }
      end
      d = perform(s, { 0 => ['arm :lead'] }, 48000)
      expect(d[24000 - 1]).to eq(0)
      expect(d[24000]).to eq(60)

      s = new_session
      s.midi_in.input = keyboard([38, 0.5r, 0.75r]) # a snare
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:drums, q: 1) { |c| MB::Sound.tr808(c) }
      end
      d = perform(s, { 0 => ['arm :drums'] }, 48000)
      expect(d[0...24000].abs.max).to eq(0)
      expect(d[24000...30000].abs.max).to be > 0.01
    end
  end

  describe 'monitors and the strip' do
    it "mutes and solos a track's monitor with the track" do
      s = new_session
      s.midi_in.input = keyboard([60, 0.5r, 3.5r])
      setup_lead(s)
      d = perform(s, {
        0 => ['arm :lead', 'bg :other, 0.constant, on: :now'],
        40 => ['mute :lead'],      # frame 32000
        60 => ['unmute :lead'],    # 48000
        80 => ['solo :other'],     # 64000
        100 => ['solo :lead'],     # 80000
        120 => ['unsolo', 'mute :"lead/live"'], # 96000: the monitor's own flag still works
      }, 104000)
      expect(d[31999]).to eq(60)
      expect(d[32000 + 240]).to eq(0) # after the 5 ms declick
      expect(d[48000 + 240]).to eq(60)
      expect(d[64000 + 240]).to eq(0)
      expect(d[80000 + 240]).to eq(60)
      expect(d[96000 + 240]).to eq(0)
      expect(s.muted?(:lead)).to eq(false)
    end
  end

  describe 'console names' do
    names = %i[rec record rec_audio record_audio stop_rec_audio stop_recording_audio arm arm_track disarm disarm_track armed armed_tracks capture capture_midi captures recorded_clips recordings]

    it 'are RecordMethods, not Kernel or Object methods, GraphNode methods, or Pry commands' do
      require 'pry'
      pry_commands = Pry::Commands.keys.map(&:to_s)
      names.each do |n|
        expect(MB::Sound.method(n).owner).to eq(MB::Sound::RecordMethods), "#{n} is defined by #{MB::Sound.method(n).owner}"
        expect(Object.new.respond_to?(n, true)).to eq(false), "#{n} is an Object method"
        expect(pry_commands).not_to include(n.to_s)
        expect(MB::Sound::GraphNode.method_defined?(n)).to eq(false), "#{n} is a GraphNode method"
      end
    end
  end
end
