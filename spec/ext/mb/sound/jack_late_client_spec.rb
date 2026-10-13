# A shared client whose JACK thread is late (FastAudio::JackMIDIInput#stall
# or FastAudio.jack_stall sleeps in its callbacks, like a thread the system
# didn't schedule in time), receiving MIDI from an outside client as in the MIDI specs, and
# playing and recording audio to and from one.  An asynchronous server
# (jackd's default) then skips cycles for it, losing what arrived in them,
# and calls it twice for one cycle; MIDI input drops the repeat instead of
# queueing its messages again, audio output plays the period it wrote in
# the first call again instead of losing it, and audio input drops the
# repeat.  A synchronous server (JackDummy's default) waits, so nothing is
# lost.  (2026-10-13, branch jack-flake-1: input_spec's read_raw example
# once read a note-off twice and lost the note-on in a full parallel run;
# audio in jack-flake-2.)
RSpec.describe('JACK ports with a late client', :aggregate_failures) do
  let(:fa) { MB::Sound::FastAudio }
  let(:client) { "mbspec_late#{rand(1 << 20)}" }

  before(:each) do
    skip @jack_error if @jack_error
    @opened = []
  end

  after(:each) do
    fa.jack_stall(0, 1)
    @opened.each(&:close)
    @keyboard&.close
    fa.jack_close
    MB::Sound::MIDI::Input.repeats_reported = nil
    MB::Sound::Jack.audio_repeats_reported = nil
  end

  # An RtMidi client sending to the inputs (made when first used, so the
  # audio examples fork with no JACK client open)
  def keyboard
    @keyboard ||= MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_late_keys', nil, 'out')
  end

  # Sends +count+ distinct note-ons 3-5 ms apart while +read+ polls, and
  # returns the note numbers read, in order.
  def send_notes(count, &read)
    got = []
    reader = Thread.new do
      deadline = MB::U.clock_now + 2
      while got.length < count && MB::U.clock_now < deadline
        got.concat(read.call)
        sleep 0.002
      end
    end
    count.times do |i|
      keyboard.send_bytes([0x90, i, 100].pack('C*'))
      sleep 0.003 + 0.002 * (i % 2)
    end
    sleep 0.1
    reader.kill.join
    got.concat(read.call)
    got.map { |_, bytes| bytes.getbyte(1) }
  end

  def late_input
    keyboard
    inp = fa::JackMIDIInput.new(client, 'midi_in', 4096).tap { |m| @opened << m }
    expect(fa.jack_connect('mbspec_late_keys:out', inp.port_name)).to eq(true)
    sleep 0.05
    inp.stall(12000, 7) # 12 ms (over two 256-frame periods) every 7th callback
    inp
  end

  # Audio: ramps of 2^-20 steps (exact in float32), so each sample says
  # which frame it was.
  def ramp(start, length)
    Numo::SFloat.new(length).seq(start) * 2.0**-20
  end

  # Frames lost (jumped over) and duplicated (gone back over) between the
  # nonzero samples of a recorded ramp
  def ramp_errors(samples)
    frames = samples.map { |v| (v * 2**20).round }.reject(&:zero?)
    lost = 0
    dup = 0
    frames.each_cons(2) do |a, b|
      lost += b - a - 1 if b - a > 1
      dup += a - b + 1 if b <= a
    end
    expect(frames.length).to be > 10000
    { lost: lost, dup: dup }
  end

  # Forks an outside JACK client (its own process, never late) that plays a
  # ramp from out_1 and records in_1 for +seconds+ once told to go; returns
  # its client name, a lambda that starts it, and one that waits for its
  # recording.  Opens this process's shared client (after forking).
  def outside_client(seconds)
    name = "mbspec_late_o#{rand(1 << 20)}"
    rd, wr = IO.pipe
    go_rd, go_wr = IO.pipe
    pid = fork do
      rd.close
      go_wr.close
      fa.jack_open(name)
      out = fa::Playback.new(nil, -1, name, 1, 1, 48000, 0, 0, 2048, 0, 2, false, 0, ['out_1'])
      inp = fa::Capture.new(nil, -1, name, 1, 48000, 0, 0, 48000, 2, false, ['in_1'])
      go_rd.read(1)
      writer = Thread.new do
        n = 1
        deadline = MB::U.clock_now + seconds
        while MB::U.clock_now < deadline
          out.write([ramp(n, 512)])
          n += 512
        end
      end
      got = []
      deadline = MB::U.clock_now + seconds
      got.concat(inp.read(512)[0].to_a) while MB::U.clock_now < deadline
      writer.join
      # Closed before exiting: a synchronous server would wait for a dead
      # client until its timeout (5 s)
      [out, inp].each(&:close)
      fa.jack_close
      wr.write(Marshal.dump(got))
      wr.close
      exit!(0)
    end
    wr.close
    go_rd.close

    fa.jack_open(MB::Sound::DeviceOutput.client_name)
    deadline = MB::U.clock_now + 5
    sleep 0.01 until fa.jack_ports("^#{name}:", false, 0).length == 2 || MB::U.clock_now > deadline
    expect(fa.jack_ports("^#{name}:", false, 0).length).to eq(2)

    go = -> { go_wr.write('g'); go_wr.close }
    recording = -> { Marshal.load(rd.read).tap { Process.wait(pid); rd.close } }
    [name, go, recording]
  end

  # A DeviceOutput and DeviceInput on the shared client, playing a ramp to
  # and recording one from an outside client for 1.5 s (the shared client
  # stalled meanwhile by FastAudio.jack_stall if +stall+).  Returns the
  # ramp recorded here, the one the outside client recorded, and the output
  # and input.
  def late_audio(stall:)
    name, go, recording = outside_client(2)

    output = MB::Sound::DeviceOutput.new(channels: 1, device: 'none', backends: [:jack], adaptive: false).tap { |o| @opened << o }
    input = MB::Sound::DeviceInput.new(channels: 1, device: 'none', backends: [:jack]).tap { |i| @opened << i }
    expect(fa.jack_connect(output.jack_ports[0], "#{name}:in_1")).to eq(true)
    expect(fa.jack_connect("#{name}:out_1", input.jack_ports[0])).to eq(true)
    sleep 0.1
    # The whole client's callback is late, before it reads the frame time,
    # like a process thread the system didn't schedule in time
    fa.jack_stall(12000, 7) if stall
    go.call

    writer = Thread.new do
      n = 1
      deadline = MB::U.clock_now + 1.5
      while MB::U.clock_now < deadline
        output.write([ramp(n, 512)])
        n += 512
      end
    end
    got = []
    deadline = MB::U.clock_now + 1.5
    got.concat(input.read(512)[0].to_a) while MB::U.clock_now < deadline
    writer.join
    fa.jack_stall(0, 1)

    [got, recording.call, output, input]
  end

  context 'with an asynchronous server' do
    before(:context) { @jack_error = JackDummy.start(sync: false) }
    after(:context) { JackDummy.stop }

    it 'receives the messages of a repeated cycle once' do
      inp = late_input
      notes = send_notes(96) { inp.read(false) }

      # The stall made the server skip and repeat cycles
      expect(inp.stats[:repeated]).to be > 0
      expect(fa.jack_info[:skipped_cycles]).to be > 0

      expect(notes.length).to be < 96 # the skipped cycles' messages are gone
      expect(notes).to eq(notes.uniq)
      expect(notes).to eq(notes.sort)
    end

    it 'warns once from MIDI::Input when JACK repeats a cycle' do
      keyboard
      inputs = Array.new(2) { MB::Sound::MIDI::Input.new(connect: 'mbspec_late_keys', api: :jack).tap { |i| @opened << i } }
      sleep 0.05
      inputs.each { |i| i.instance_variable_get(:@input).stall(12000, 7) }

      notes = nil
      expect {
        notes = send_notes(96) { inputs.flat_map(&:read_raw) }
      }.to output(/\AJACK ran a cycle twice for MIDI input .*midi_in.*`jackd --sync`[^\n]*\n\z/m).to_stderr
      expect(inputs.sum { |i| i.instance_variable_get(:@input).repeated }).to be > 0
      expect(notes.tally.values.max).to be <= 2 # once per input
    end

    it 'plays and records the audio of a repeated cycle once' do
      here = there = output = input = nil
      expect {
        here, there, output, input = late_audio(stall: true)
      }.to output(/\AJACK ran a cycle twice for audio (output|input) .*`jackd --sync`[^\n]*\n\z/m).to_stderr

      expect(fa.jack_info[:skipped_cycles]).to be > 0
      expect(output.stats[:repeated]).to be > 0
      expect(input.stats[:repeated]).to be > 0

      # Without the dedupe, the outside client lost a period of the ramp for
      # each repeated cycle, and this input recorded one twice (cycles this
      # client missed are gone, so frames may be lost here)
      expect(ramp_errors(there)).to eq(lost: 0, dup: 0)
      expect(ramp_errors(here)[:dup]).to eq(0)
    end
  end

  context 'with a synchronous server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    it 'loses nothing when the client is late' do
      inp = late_input
      notes = send_notes(96) { inp.read(false) }

      expect(notes).to eq((0...96).to_a)
      expect(inp.stats).to include(repeated: 0, dropped: 0)
      expect(fa.jack_info).to include(skipped_cycles: 0, repeated_cycles: 0)
    end

    it 'loses no audio when the client is late' do
      here, there, output, input = late_audio(stall: true)
      expect(ramp_errors(there)).to eq(lost: 0, dup: 0)
      expect(ramp_errors(here)).to eq(lost: 0, dup: 0)
      expect(output.stats[:repeated]).to eq(0)
      expect(input.stats[:repeated]).to eq(0)
    end
  end
end
