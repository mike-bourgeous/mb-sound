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

  # Compares two clients' FastAudio.jack_frame_log over the span both
  # logged: the numbers of server cycles only the first ran, only the
  # second ran, and callbacks of either that ran into the next cycle.
  # (Frame times start near zero on the spec's fresh server, so they don't
  # wrap.)
  def compare_cycles(first, second)
    lo = [first[0][0], second[0][0]].max
    hi = [first[-1][0], second[-1][0]].min
    a = first.select { _1[0].between?(lo, hi) }
    b = second.select { _1[0].between?(lo, hi) }
    a_frames = a.map(&:first).uniq
    b_frames = b.map(&:first).uniq
    [(a_frames - b_frames).length, (b_frames - a_frames).length, (a + b).count { _1[0] != _1[1] }]
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
      fa.jack_frame_log(true)
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
      info = fa.jack_info.slice(:skipped_cycles, :repeated_cycles).merge(out_repeated: out.stats[:repeated], in_repeated: inp.stats[:repeated])
      frames = fa.jack_frame_log(false)
      # Closed before exiting: a synchronous server would wait for a dead
      # client until its timeout (5 s)
      [out, inp].each(&:close)
      fa.jack_close
      wr.write(Marshal.dump([got, info, frames]))
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
    recording = -> { Marshal.load(rd.read).tap { Process.wait(pid); rd.close; _, @outside_info, @outside_frames = _1 }[0] }
    [name, go, recording]
  end

  # A DeviceOutput and DeviceInput on the shared client, playing a ramp to
  # and recording one from an outside client for 1.5 s (the shared client
  # stalled meanwhile by FastAudio.jack_stall if +stall+).  Returns the
  # ramp recorded here, the one the outside client recorded, and the output
  # and input.  @late_frames and @outside_frames are the two clients'
  # FastAudio.jack_frame_log, this one's spanning the outside client's.
  def late_audio(stall:)
    name, go, recording = outside_client(2)

    # (conceal: :silence: the ramp checks count frames between nonzero
    # samples, and concealment fills underruns with earlier ramp frames)
    output = MB::Sound::DeviceOutput.new(channels: 1, device: 'none', backends: [:jack], adaptive: false, conceal: :silence).tap { |o| @opened << o }
    input = MB::Sound::DeviceInput.new(channels: 1, device: 'none', backends: [:jack]).tap { |i| @opened << i }
    expect(fa.jack_connect(output.jack_ports[0], "#{name}:in_1")).to eq(true)
    expect(fa.jack_connect("#{name}:out_1", input.jack_ports[0])).to eq(true)
    sleep 0.1
    # The whole client's callback is late, before it reads the frame time,
    # like a process thread the system didn't schedule in time
    fa.jack_stall(12000, 7) if stall
    fa.jack_frame_log(true)
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
    there = recording.call
    @late_frames = fa.jack_frame_log(false)

    [got, there, output, input]
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

      per_input = nil
      expect {
        per_input = Array.new(2) { [] }
        send_notes(96) {
          inputs.each_with_index.flat_map { |inp, k| inp.read_raw.each { |frame, bytes| per_input[k] << [bytes.getbyte(1), frame] } }
        }
      }.to output(/\AJACK ran a cycle twice for MIDI input .*midi_in.*`jackd --sync`[^\n]*\n\z/m).to_stderr
      expect(inputs.sum { |i| i.instance_variable_get(:@input).repeated }).to be > 0

      # Once per input: a repeated cycle (the same frame time) is never
      # queued twice.  A note again a whole number of periods later is a
      # port buffer read again after a client missed a cycle (the sender,
      # an RtMidi JACK client, kept its last period's events: under
      # Valgrind it can miss cycles too; memcheck, 2026-10-25, a note read
      # three times by two inputs), which no receiver can tell from a real
      # repeat of the same bytes, so those are allowed (omnibus13).
      period = fa.jack_info[:buffer_size]
      per_input.each do |events|
        events.group_by(&:first).each do |note, seen|
          frames = seen.map(&:last)
          expect(frames.uniq.length).to eq(frames.length), "note #{note} queued twice at the same frame: #{frames}"
          frames.sort.each_cons(2) do |a, b|
            expect((b - a) % period).to eq(0), "note #{note} again #{b - a} frames later (not a stale period): #{frames}"
          end
        end
      end
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
      # Beyond the stall (which delays the whole graph, so both clients
      # miss its cycles), either client can be late on its own under load or
      # Valgrind, losing audio that can't be recovered either:
      # - A cycle the outside client misses and this one runs loses that
      #   period of its recording, and its output port keeps the period it
      #   wrote last, which this input records again (lost there, dup here).
      # - A cycle this client misses leaves its output port holding its
      #   last period, recorded again there (dup there; lost here).
      # - A callback of either that runs into the next cycle (preempted
      #   after reading the frame time) can read the other client's port
      #   after that client's next cycle wrote it, or write its own after
      #   the other read it, or (a unit reading the frame time again) see
      #   the next cycle's frame time and drop that cycle as a repeat: up
      #   to a period lost and one duplicated each way, though neither
      #   client skipped a cycle.  (Units read the frame time themselves on
      #   purpose: a unit stalled after process() read it must see the
      #   repeat, as MIDI input's stall shows.)
      # Jack.info's skip counters can't tell these apart (fixes-9 allowed
      # the outside client's skips beyond this one's; jack-spec-1,
      # 2026-10-15: 5 of 6 Valgrind runs and 3 of 5 under 16 busy loops
      # still failed, e.g. 76 and 78 skips with 512 lost and 256 dup there,
      # 512 dup here; a capture unit of the outside client read 21760 in
      # the callback for 21504 and then dropped 21760), so the frame logs
      # count each kind.
      # Without the dedupe, 8960 frames (35 periods) are lost there and
      # duplicated here.
      period = fa.jack_info[:buffer_size]
      outside_missed, here_missed, overran = compare_cycles(@late_frames, @outside_frames).map { _1 * period }
      there_errors = ramp_errors(there)
      expect(there_errors[:dup]).to be <= here_missed + overran
      expect(there_errors[:lost]).to be <= outside_missed + overran
      expect(ramp_errors(here)[:dup]).to be <= outside_missed + overran
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
