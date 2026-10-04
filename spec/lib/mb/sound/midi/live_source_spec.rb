RSpec.describe(MB::Sound::MIDI::LiveSource, :aggregate_failures) do
  # A MIDI::Input stand-in that returns queued raw messages: RtMidi deltas
  # (seconds since the previous message), or JACK frame times with +rate+.
  class FakeLiveInput
    attr_reader :frame_rate
    attr_accessor :queue

    def initialize(frame_rate: nil)
      @frame_rate = frame_rate
      @queue = []
      @closed = false
    end

    def push(*messages)
      @queue.concat(messages)
      self
    end

    def read_raw
      @queue.tap { @queue = [] }
    end

    def frame_times?
      !@frame_rate.nil?
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  # A DeviceOutput stand-in for its clock: queue sizes in device frames, and
  # a JACK clock if given.
  class FakeClockOutput
    attr_accessor :queue_limit, :period, :device_rate, :queued, :jack_clock

    def initialize(queue_limit: 2400, period: 128, device_rate: 48000.0, queued: 2400, jack_clock: nil)
      @queue_limit = queue_limit
      @period = period
      @device_rate = device_rate
      @queued = queued
      @jack_clock = jack_clock
    end

    def stats
      { queued: @queued }
    end
  end

  around(:each) do |ex|
    saved = ENV.delete('MIDI_TIMING')
    ex.run
  ensure
    saved ? ENV['MIDI_TIMING'] = saved : ENV.delete('MIDI_TIMING')
  end

  let(:on) { [0x90, 60, 100].pack('C*') }
  let(:off) { [0x80, 60, 0].pack('C*') }
  let(:cc) { [0xb0, 1, 64].pack('C*') }
  let(:input) { FakeLiveInput.new }
  let(:buffer) { Rational(512, 48000) }

  # Reads buffer +n+ (0-based) of +buffer+ seconds
  def read_buffer(src, n)
    src.read(n * buffer, (n + 1) * buffer)
  end

  describe 'timing' do
    it 'is :exact by default, MIDI_TIMING wins over the argument, and unknown modes raise' do
      expect(MB::Sound::MIDI::LiveSource.new(input).timing).to eq(:exact)
      expect(MB::Sound::MIDI::LiveSource.new(input, timing: ':asap').timing).to eq(:asap)
      ENV['MIDI_TIMING'] = 'asap'
      expect(MB::Sound::MIDI::LiveSource.new(input, timing: :exact).timing).to eq(:asap)
      ENV['MIDI_TIMING'] = 'soon'
      expect { MB::Sound::MIDI::LiveSource.new(input) }.to raise_error(ArgumentError, /Unknown MIDI timing "soon"/)
    end
  end

  describe ':asap timing' do
    it 'places every event at the start of the read that polled it' do
      src = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
      expect(read_buffer(src, 0)).to eq([])

      input.push([0.0, on], [0.004, cc])
      events = read_buffer(src, 1)
      expect(events.map(&:type)).to eq([:note_on, :cc])
      expect(events.map(&:time)).to eq([buffer, buffer])

      input.push([0.5, off])
      expect(read_buffer(src, 2).map { |e| [e.type, e.time] }).to eq([[:note_off, 2 * buffer]])
      expect(src.latency).to be_nil
    end
  end

  describe ':exact timing with RtMidi deltas and no output' do
    let(:src) { MB::Sound::MIDI::LiveSource.new(input) }

    it 'anchors the newest first event one buffer after the start of its read, keeping the spacing' do
      expect(read_buffer(src, 0)).to eq([])

      # Input times 0, 2 ms, 5 ms; the newest (5 ms) goes to the end of
      # buffer 1 (its start plus one buffer), the others keep their spacing
      input.push([0.0, on], [0.002, cc], [0.003, off])
      anchor = 2 * buffer - Rational(5, 1000)
      events = read_buffer(src, 1)
      expect(events.map(&:type)).to eq([:note_on, :cc])
      expect(events.map(&:time)).to eq([anchor, anchor + Rational(2, 1000)])
      expect(src.latency).to eq(buffer)

      # The newest waits for the next read, at the start of buffer 2
      input.push([0.004, cc])
      events = read_buffer(src, 2)
      expect(events.map { |e| [e.type, e.time] }).to eq([[:note_off, 2 * buffer], [:cc, anchor + Rational(9, 1000)]])
      expect(src.late_events).to eq(0)
    end

    it 'keeps the spacing across reads, so events between reads are not snapped to buffers' do
      read_buffer(src, 0)
      input.push([0.0, on])
      read_buffer(src, 1)
      anchor = 2 * buffer # input time 0 arrived at read 1's start, plus one buffer

      # Input times (in buffers after the anchor event) of events arriving
      # before each read, i.e. during the buffer before it
      arrivals = { 2 => [0.3], 3 => [1.9], 4 => [2.05, 2.6], 6 => [4.5] }
      deltas = []
      last = 0.0
      times = []
      (2..9).each do |n|
        (arrivals[n] || []).each do |b|
          t = b * buffer.to_f
          deltas << t - last
          input.push([t - last, cc])
          last = t
        end
        times.concat(read_buffer(src, n).map(&:time))
      end

      sums = deltas.each_with_object([0r]) { |d, acc| acc << acc.last + Rational((d * 1e6).round, 1_000_000) }
      expect(times).to eq(sums.map { |s| anchor + s })
      expect(src.late_events).to eq(0)
      expect(src.reanchors).to eq(0)
    end

    it 'moves events that would be before the read to its start, counting them' do
      read_buffer(src, 0)
      input.push([0.0, on])
      read_buffer(src, 1) # anchors input time 0 at 2 buffers
      (2..5).each { |n| read_buffer(src, n) }

      # 6 buffers of stream time but only 3.5 buffers of input time passed:
      # late by less than the latency, so moved to the start of the read
      input.push([3.5 * buffer.to_f, cc])
      expect(read_buffer(src, 6).map(&:time)).to eq([6 * buffer])
      expect(src.late_events).to eq(1)
      expect(src.reanchors).to eq(0)
    end

    it 're-anchors when the mapping is off by more than the latency (e.g. a paused session)' do
      read_buffer(src, 0)
      input.push([0.0, on])
      read_buffer(src, 1)

      # Ten seconds of input time while the stream was paused: the newest
      # event is anchored again one buffer after the read's start
      input.push([10.0, off], [0.001, cc])
      events = read_buffer(src, 2) + read_buffer(src, 3)
      expect(src.reanchors).to eq(1)
      expect(events.map { |e| [e.type, e.time] }).to eq([
        [:note_on, 2 * buffer], [:note_off, 3 * buffer - Rational(1, 1000)], [:cc, 3 * buffer]
      ])
    end

    it 'uses a given latency' do
      src = MB::Sound::MIDI::LiveSource.new(input, latency: 20.ms)
      read_buffer(src, 0)
      input.push([0.0, on])
      events = (1..5).flat_map { |n| read_buffer(src, n) }
      expect(events.map(&:time)).to eq([buffer + Rational(20, 1000)])
      expect(src.latency).to eq(Rational(1, 50))
    end
  end

  describe ':exact timing with an output clock' do
    let(:output) { FakeClockOutput.new(queue_limit: 2400, period: 128, queued: 1800) }

    it 'anchors RtMidi events to the playing position plus the queue, period, and buffer' do
      src = MB::Sound::MIDI::LiveSource.new(input, output: output)
      read_buffer(src, 0)
      input.push([0.0, on])
      events = (1..10).flat_map { |n| read_buffer(src, n) }

      latency = Rational(2400 + 128 + 512, 48000)
      expect(src.latency).to eq(latency)
      expect(events.map(&:time)).to eq([buffer - Rational(1800, 48000) + latency])
    end

    it 'places JACK events on the queued frame that plays at their frame plus the latency' do
      jack = FakeLiveInput.new(frame_rate: 48000)
      output.jack_clock = { frame_time: 0xffff_ff00, read_pos: 5000, frames_played: 6000, write_pos: 7000 }
      src = MB::Sound::MIDI::LiveSource.new(jack, output: output)
      expect(src.frame_exact?).to eq(true)

      # Frames 0x40 (after the counter wraps) and 0xffff_ff80, read at
      # stream time 1 s, which the output will queue at frame 7000
      expect(src.read(0, 1)).to eq([])
      jack.push([0xffff_ff80, on], [0x40, off])
      from = 1r
      latency = 2400 + 128 + 512
      events = src.read(from, from + buffer) + src.read(from + buffer, 2)
      expect(events.map(&:time)).to eq([
        from + Rational(5000 + 0x80 + latency - 7000, 48000),
        from + Rational(5000 + 0x140 + latency - 7000, 48000),
      ])
      expect(src.latency).to eq(Rational(latency, 48000))
    end

    it 'follows a changing queue limit without moving events backwards' do
      jack = FakeLiveInput.new(frame_rate: 48000)
      output.jack_clock = { frame_time: 1000, read_pos: 5000, frames_played: 6000, write_pos: 6800 }
      src = MB::Sound::MIDI::LiveSource.new(jack, output: output)

      # The note-on plays 3040 frames after frame 1000 (frame 8040, ring
      # frame 8040, 1240 frames after read 0's start)
      jack.push([1000, on])
      events = read_buffer(src, 0)

      # With a smaller queue the note-off would be earlier than the note-on
      output.queue_limit = 1200
      output.jack_clock = output.jack_clock.merge(write_pos: 6800 + 512)
      jack.push([1010, off])
      events += (1..3).flat_map { |n| read_buffer(src, n) }

      expect(events.map { |e| [e.type, e.time] }).to eq([[:note_on, Rational(1240, 48000)], [:note_off, Rational(1240, 48000)]])
      expect(src.latency).to eq(Rational(1200 + 128 + 512, 48000))
    end

    it 'falls back to the free-running anchor for JACK input without a JACK output' do
      jack = FakeLiveInput.new(frame_rate: 48000)
      src = MB::Sound::MIDI::LiveSource.new(jack, output: output)
      expect(src.frame_exact?).to eq(false)

      read_buffer(src, 0)
      jack.push([0xffff_fff0, on], [0x10, off])
      latency = Rational(2400 + 128 + 512, 48000)
      events = (1..10).flat_map { |n| read_buffer(src, n) }
      newest = buffer - Rational(1800, 48000) + latency
      expect(events.map(&:time)).to eq([newest - Rational(32, 48000), newest])
    end

    it 'follows a new output given with #output=, anchoring again at the next events' do
      src = MB::Sound::MIDI::LiveSource.new(input, output: output)
      read_buffer(src, 0)
      input.push([0.0, on])
      read_buffer(src, 1)
      expect(src.latency).to eq(Rational(2400 + 128 + 512, 48000))

      low = FakeClockOutput.new(queue_limit: 512, period: 128, queued: 256)
      src.output = low
      expect(src.output).to equal(low)
      input.push([0.001, off])
      events = (2..5).flat_map { |n| read_buffer(src, n) }

      latency = Rational(512 + 128 + 512, 48000)
      expect(src.latency).to eq(latency)
      expect(events.select(&:note_off?).map(&:time)).to eq([2 * buffer - Rational(256, 48000) + latency])
      expect(src.reanchors).to eq(0)
    end
  end

  describe 'Source behavior' do
    it 'never ends while open, ignores seeks, and closes only inputs it opened' do
      src = MB::Sound::MIDI::LiveSource.new(input)
      expect(src.ended?).to eq(false)
      expect(src.seek(3)).to equal(src)
      expect(src.restart).to equal(src)
      expect(src.generation).to eq(0)
      expect(src.music_end).to be_nil

      src.close
      expect(src.closed?).to eq(true)
      expect(src.ended?).to eq(true)
      expect(input.closed?).to eq(false)
    end

    it 'opens and closes its own MIDI::Input' do
      fake = FakeLiveInput.new
      expect(MB::Sound::MIDI::Input).to receive(:new).with(connect: 'Launchkey', api: :alsa).and_return(fake)
      src = MB::Sound::MIDI::LiveSource.new(connect: 'Launchkey', api: :alsa)
      expect(src.input).to equal(fake)
      src.close
      expect(fake.closed?).to eq(true)
    end

    it 'drops note-offs for notes held before it opened' do
      src = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
      input.push([0.0, [0x80, 50, 0].pack('C*')], [0.0, on], [0.0, off])
      expect(src.read(0, buffer).map { |e| [e.type, e.note] }).to eq([[:note_on, 60], [:note_off, 60]])
    end

    it 'parses several messages in one record' do
      src = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
      input.push([0.0, on + cc])
      expect(src.read(0, buffer).map(&:type)).to eq([:note_on, :cc])
    end
  end

  describe 'Streams' do
    it 'reads a live source through Stream.for, with transforms' do
      src = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
      stream = MB::Sound::MIDI::Stream.for(src)
      expect(stream.source).to equal(src)

      reader = stream.channel(0).transpose(12).reader
      input.push([0.0, on], [0.0, [0x91, 40, 100].pack('C*')])
      expect(reader.next(buffer).map { |e| [e.note, e.time] }).to eq([[72, 0]])
    end

    it 'wraps a MIDI::Input with Stream.for' do
      inp = MB::Sound::MIDI::Input.allocate
      allow(inp).to receive_messages(read_raw: [[0.0, on]], frame_times?: false)
      stream = MB::Sound::MIDI::Stream.for(inp)
      expect(stream.source).to be_a(MB::Sound::MIDI::LiveSource)
      expect(stream.source.input).to equal(inp)
    end

    it 'opens a live stream with Stream.live' do
      fake = FakeLiveInput.new
      expect(MB::Sound::MIDI::Input).to receive(:new).with(connect: 'keys').and_return(fake)
      stream = MB::Sound::MIDI::Stream.live(connect: 'keys', timing: :asap, latency: 0.01)
      expect(stream.source.timing).to eq(:asap)

      fake.push([0.0, cc])
      expect(stream.reader.next(buffer).map(&:type)).to eq([:cc])
      stream.source.close
      expect(fake.closed?).to eq(true)
    end
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    around(:each) do |ex|
      names = %w[AUDIO_BACKEND OUTPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE JACK_CLIENT_NAME AUDIO_PROFILE AUDIO_LATENCY AUDIO_BUFFER]
      saved = names.to_h { |k| [k, ENV.delete(k)] }
      ex.run
    ensure
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    before(:each) do
      skip @jack_error if @jack_error
      ENV['AUDIO_BACKEND'] = 'jack'
      ENV['OUTPUT_DEVICE'] = 'none'
      ENV['JACK_CLIENT_NAME'] = "mbspec_live#{rand(1 << 20)}"
      @opened = []
    end

    after(:each) do
      @opened.reverse_each(&:close)
      MB::Sound::Jack.close
    end

    def open(obj)
      @opened << obj
      obj
    end

    # Plays like a Session (read MIDI for a buffer, then write the buffer)
    # with a click on the sample of each note-on, while another JACK client
    # sends notes; returns the clicks' captured indices by note number and
    # the source.
    def play_notes(timing:, notes: 12, buffer_size: 512)
      out = open(MB::Sound::DeviceOutput.new(channels: 1, latency: 0.2, adaptive: false, capture: 48000 * 4))
      keyboard = open(MB::Sound::FastMIDI::Output.new(:jack, "#{ENV['JACK_CLIENT_NAME']}_keys", nil, 'out'))
      inp = open(MB::Sound::MIDI::Input.new(connect: "#{ENV['JACK_CLIENT_NAME']}_keys"))
      reference = open(MB::Sound::MIDI::Input.new(connect: "#{ENV['JACK_CLIENT_NAME']}_keys"))
      expect(inp.api).to eq(:jack)
      src = open(MB::Sound::MIDI::LiveSource.new(inp, output: out, timing: timing))

      sender = Thread.new do
        sleep 0.3
        notes.times do |i|
          keyboard.send_bytes([0x90, 40 + i, 100].pack('C*'))
          sleep 0.0137 + 0.011 * (i % 3)
        end
        sleep 0.5
      end

      clicks = {}
      n = 0
      while sender.alive?
        from = Rational(n * buffer_size, 48000)
        buf = Numo::SFloat.zeros(buffer_size)
        src.read(from, from + Rational(buffer_size, 48000)).each do |e|
          next unless e.note_on?
          offset = (e.time - from) * 48000
          expect(offset.denominator).to eq(1) if timing == :exact
          buf[offset.floor] = e.note
        end
        out.write([buf])
        n += 1
      end

      wait_until = MB::U.clock_now + 2
      sleep 0.01 until out.frames_played > out.frames_written + 9600 || MB::U.clock_now > wait_until
      played = out.captured[0]
      played.to_a.each_with_index { |v, i| clicks[v.round] = i if v != 0 }

      [clicks, reference.read_raw, out, src]
    end

    it 'places JACK MIDI on the output sample that plays at its frame plus the latency' do
      clicks, raw, out, src = play_notes(timing: :exact)
      expect(src.frame_exact?).to eq(true)
      expect(out.underruns).to eq(1) # only before the first write
      expect(raw.length).to eq(12)
      expect(clicks.length).to eq(12)
      expect(src.late_events).to eq(0)

      latency = src.latency * 48000
      expect(latency).to eq(out.queue_limit + 256 + 512)

      clock = out.jack_clock
      expected = raw.to_h { |frame, bytes|
        delta = ((frame - clock[:frame_time] + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
        [bytes.bytes[1], clock[:frames_played] + delta + latency]
      }
      expect(clicks).to eq(expected)
    end

    it 'snaps JACK MIDI to buffers with :asap timing' do
      clicks, _raw, _out, src = play_notes(timing: :asap)
      expect(clicks.length).to eq(12)
      expect(src.latency).to be_nil

      # Every click is on a buffer boundary of the written audio (the first
      # write started at frame 0 of the queue, but the captured audio has
      # silence from before it)
      starts = clicks.values.map { |i| i % 512 }.uniq
      expect(starts.length).to eq(1)
    end
  end
end
