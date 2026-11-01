RSpec.describe(MB::Sound::Arrangement::Wires) do
  # 120 BPM at 48kHz: one bar (a whole note, 2 s) is 96000 frames, a beat
  # 24000
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

  # Plays +lines+ (buffer index => console lines, run before the buffer
  # that starts at or after frame 800 * index) in buffers of +sizes+
  # (cycled) for +frames+ frames, in one console binding.  Returns the
  # first channel.
  def perform(session, lines, frames, sizes = [800], binding: MB::Sound::Take.console_binding)
    pending = lines.sort.to_h
    out = []
    done = 0
    sizes.cycle do |n|
      break if done >= frames
      pending.keys.select { |i| i * 800 <= done }.each do |i|
        pending.delete(i).each { |code| MB::Sound::Session.with_context(session: session) { binding.eval(code) } }
      end
      n = [n, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  SETUP = [
    'track(:lead, q: 1) { |c| c.number * c.gate }',
    'bg :clock, 0.constant, on: :now',
    'riff = seq(C4, E4, G4, nil).n4.loop.named(:riff)',
    'hop = seq(A4, B4).n8.loop.named(:hop)',
  ].freeze

  SIZES = [[800], *[[367, 368], [64], [1001, 13]]].freeze

  describe '#wire' do
    it 'plays a stream through the track patch from its launch point, rewires on the exact frame (ending held notes), and unwires, at any buffer size' do
      lines = {
        0 => SETUP,
        10 => ['wire :lead, riff.stream'],               # lands on bar 2
        255 => ['wire :lead, hop.stream, on: :beat'],    # bar 3 beat 2 (216000), C4 still held
        300 => ['unwire :lead'],                         # bar 4
      }
      results = [[800], *slow_tier(SIZES.drop(1))].map { |sizes|
        s = new_session
        [perform(s, lines, 96000 * 4, sizes), s]
      }
      d, s = results[0]
      results.drop(1).each { |dd, _| expect(dd).to eq(d) }

      expect(d[0...96000].abs.max).to eq(0)
      expect(d[96000]).to eq(60)          # bar 2: the clip in timeline phase
      expect(d[96000 + 24000]).to eq(64)
      expect(d[96000 + 48000]).to eq(67)
      expect(d[96000 + 72000]).to eq(0)   # the rest
      expect(d[192000]).to eq(60)
      expect(d[215999]).to eq(60)         # C4 held up to the rewire...
      expect(d[216000]).to eq(69)         # ...where hop plays in phase (its third eighth, A4)
      expect(d[216000 + 12000]).to eq(71)
      expect(d[288000 + 240..].abs.max).to eq(0) # unwired on bar 4 (the monitor's 5 ms declick)

      kinds = s.journal.changes.select { |e| [:lead, :"lead/live", :"lead/wire"].include?(e.subject) }.map { |e| [e.kind, e.subject, e.lands.to_s] }
      expect(kinds).to eq([
        [:arm, :lead, '1:1.333'], [:wire, :"lead/wire", '2:1'], [:bg, :"lead/live", '2:1'],
        [:arm, :lead, '3:1.5'], [:wire, :"lead/wire", '3:2'], # (the monitor plays on)
        [:stop, :"lead/live", '4:1'], [:unwire, :"lead/wire", '4:1'], [:disarm, :lead, '4:1'],
      ])
      expect(s.arrangement.wires).to eq({})
      expect(s.arrangement.arm_problems).to eq([])
    end

    it 'keeps the track clip playing beside the stream, and says so in tracks and stop' do
      s = new_session
      b = MB::Sound::Take.console_binding
      perform(s, { 0 => SETUP + ['bg :lead, riff', 'wire :lead, hop.stream'] }, 9600, binding: b)
      MB::Sound::Session.with_context(session: s) do
        expect(b.eval('wires')).to eq({ lead: 'hop.stream' })
        expect(s.arrangement.track_info[:lead]).to eq('q:1 riff (playing, wired: hop.stream)')
        expect(s.players.keys).to include(:lead, :"lead/live")
        expect(s.players[:"lead/live"]).to include('wired: hop.stream')
        expect { b.eval('stop :lead') }.to output(/stop :lead: its wire \(hop\.stream\) still plays through :"lead\/live" \(unwire :lead\)/).to_stderr
      end
    end

    it 'plays live input through transforms (a tap of the default input), on exact frames at any buffer size' do
      played = [[60, 2.1r, 2.35r], [64, 2.6r, 2.9r]]
      lines = { 0 => SETUP, 10 => ['wire :lead, MB::Sound::Session.current.midi_in.stream.transpose(12), on: :bar'] }
      results = [[800], *slow_tier(SIZES.drop(1))].map { |sizes|
        s = new_session
        s.midi_in.input = keyboard(*played)
        perform(s, lines, 96000 * 2, sizes)
      }
      results.drop(1).each { |d| expect(d).to eq(results[0]) }
      d = results[0]
      expect(d[0...100800].abs.max).to eq(0)
      expect(d[100800]).to eq(72)  # 2.1 s
      expect(d[112799]).to eq(72)
      expect(d[112800]).to eq(0)
      expect(d[124800]).to eq(76)
    end

    it 'records the stream with rec, as live input' do
      s = new_session
      perform(s, { 0 => SETUP, 10 => ['wire :lead, riff.stream', 'rec 1'] }, 96000 * 3 + 800)
      clip = s.arrangement.captures[:lead_1]
      expect(clip.events.map { |e| [e.start, e.length, e.value] }).to eq([[0r, 1/4r, 60], [1/4r, 1/4r, 64], [1/2r, 1/4r, 67]])
      expect(s.arrangement.tracks[:lead].clip).to equal(clip)
    end

    it 'is one undo step: cancelled before it lands, restored at the next bar after' do
      s = new_session
      b = MB::Sound::Take.console_binding
      d = perform(s, { 0 => SETUP, 10 => ['wire :lead, riff.stream', 'undo'] }, 96000 * 2, binding: b)
      expect(d.abs.max).to eq(0)
      expect(s.arrangement.wires).to eq({})
      expect(s.arrangement.arm_problems).to eq([])

      s = new_session
      d = perform(s, { 0 => SETUP, 10 => ['wire :lead, riff.stream, on: :now'], 130 => ['undo'] }, 96000 * 3)
      expect(d[8000]).to eq(0)          # (C4, begun before the wire, isn't chased)
      expect(d[30000]).to eq(64)
      expect(d[192000 + 240..].abs.max).to eq(0) # undone at bar 3
      expect(s.midi_in(:"lead/wire").wired).to be_nil
      expect(s.arrangement.armed).to eq({})
      expect(s.arrangement.arm_problems).to eq([])
    end

    it 'says what to write for clips, kits, names, and missing streams' do
      s = new_session
      b = MB::Sound::Take.console_binding
      perform(s, { 0 => SETUP }, 800, binding: b)
      MB::Sound::Session.with_context(session: s) do
        expect { b.eval('wire :lead, riff') }.to raise_error(ArgumentError, /a clip plays on :lead's instrument with swap :lead, clip.*wire :lead, clip\.stream/)
        expect { b.eval('connect :lead, riff') }.to raise_error(ArgumentError, /swap :lead, clip/)
        expect { b.eval('wire :lead, :keys') }.to raise_error(ArgumentError, /arm :lead, input: :keys/)
        expect { b.eval('wire :lead') }.to raise_error(ArgumentError, /give the stream/)
        expect { b.eval('wire :lead, echo(1.n8, 3)') }.to raise_error(ArgumentError, /midi\.through\(echo/)
        expect { b.eval('wire :leed, riff.stream') }.to raise_error(ArgumentError, /No track :leed to wire \(tracks: :lead\).*:lead/m)
        expect { b.eval('unwire :lead') }.to raise_error(ArgumentError, /No stream is wired into :lead \(nothing is wired\)/)
        expect(b.eval('unwire')).to eq([])
      end
    end
  end

  describe 'arm ..., input: stream' do
    it 'wires the track now' do
      s = new_session
      d = perform(s, { 0 => SETUP + ['arm :lead, input: riff.stream'] }, 48000)
      expect(d[0]).to eq(60)
      expect(d[24000]).to eq(64)
      expect(s.arrangement.armed).to eq({ lead: :"lead/wire" })
      expect(s.arrangement.wires).to eq({ lead: 'riff.stream' })
    end

    it 'unwires when the track is armed on live input, and disarm unwires' do
      s = new_session
      s.midi_in.input = keyboard([60, 100, 101]) # (a stand-in keyboard: no live MIDI)
      d = perform(s, { 0 => SETUP + ['arm :lead, input: riff.stream'], 40 => ['arm :lead, monitor: false'], 60 => ['disarm'] }, 96000)
      expect(d[30000]).to eq(64)
      expect(d[32000 + 240..].abs.max).to eq(0)
      expect(s.midi_in(:"lead/wire").wired).to be_nil
      expect(s.arrangement.arm_problems).to eq([])
    end
  end

  describe 'takes' do
    it 'replay a wired stream bit for bit from the MIDI log, at other buffer sizes' do
      transport = MB::Sound::Sequence::Transport.new(bpm: 120)
      s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
      sessions << s
      b = MB::Sound::Take.console_binding
      t = MB::Sound::Take.new(session: s)
      lines = { 0 => SETUP, 10 => ['wire :lead, riff.stream.echo(1.n8, 2, pitch: 12)'], 250 => ['wire :lead, hop.stream, on: :beat'], 300 => ['unwire :lead'] }
      out = []
      (96000 * 4 / 800).times do |i|
        lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: s) { t.line(code, b) } }
        out << s.process_buffer(800)[0].dup
      end
      live = SpecBuffers.join(out)
      expect(live.abs.max).to be > 60
      expect(t.midi.keys).to include(:"lead/wire")

      path = tmp_path('take.rb')
      expect { t.save(path) }.to output(/Saved/).to_stdout
      load path
      r = MB::Sound::Take::Replay.last
      [[800], *slow_tier([[367, 368]], keep: 0)].each do |sizes|
        got = []
        r.render(MB::Sound::NullOutput.new(channels: 1, sleep: false), buffer_sizes: sizes, tail: 0) { |mix| got << mix[0].dup }
        data = SpecBuffers.join(got)
        expect(data.length).to be >= live.length
        expect(data[0...live.length]).to eq(live), "buffer sizes #{sizes}"
      end
    end
  end
end
