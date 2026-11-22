# The timing proof of MIDI out on JACK (midi-out-1): a Session plays a clip
# on a MIDI out track whose port is looped back (through the private dummy
# JACK server) into a JACK MIDI input that records each message's JACK
# frame.  Each note must arrive on the JACK frame where the Session's audio
# of the note's frame leaves (the playback ring's published mapping, the
# one #jack_clock documents) plus the offset, exactly, at any buffer size
# and tempo, and the note's session frame must be the clip position's
# sample (the same at every buffer size).
RSpec.describe('MIDI out on JACK (timing)', :aggregate_failures) do
  NAMES = %w[AUDIO_BACKEND OUTPUT_DEVICE INPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE JACK_CLIENT_NAME AUDIO_PROFILE].freeze

  around(:each) do |ex|
    saved = NAMES.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }

  before(:each) do
    skip @jack_error if @jack_error
    ENV['AUDIO_BACKEND'] = 'jack'
    ENV['OUTPUT_DEVICE'] = 'none'
    ENV['MIDI_API'] = 'jack'
    ENV['JACK_CLIENT_NAME'] = "mbspec_mo#{rand(1 << 20)}"
    @opened = []
    @synth = MB::Sound::FastMIDI::Input.new(:jack, "#{ENV['JACK_CLIENT_NAME']}_synth", nil, 'in', 1000)
  end

  after(:each) do
    @opened.reverse_each(&:close)
    @synth&.close
    MB::Sound::MIDI::Destination.close
    MB::Sound::Jack.close
  end

  def open(obj)
    @opened << obj
    obj
  end

  def delta(a, b)
    ((b - a + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
  end

  # Plays +clip+ on a MIDI out track for +frames+ frames in +size+-frame
  # buffers at +bpm+ with +offset+, driving the Session's buffers here (each
  # written to the JACK output, which paces them).  Returns [notes, sent]:
  # notes as [JACK frame received, bytes], and for each message the
  # destination sent: [session frame, JACK frame it was sent for, the JACK
  # frame the playback's clock gives that frame's audio at the moment of
  # sending].
  def play(clip, size:, bpm:, offset:, frames:)
    out = open(MB::Sound::DeviceOutput.new(channels: 1, buffer_size: size, latency: 0.15, adaptive: false))
    capture = open(MB::Sound::MIDI::Input.new) # our own midi_in: JACK frame times
    session = open(MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: bpm),
                                         channels: 1, buffer_size: size, realtime: false, raise_errors: true))
    dest = MB::Sound.midi_out("#{ENV['JACK_CLIENT_NAME']}_synth", offset: offset)
    expect(dest.port.name).to eq("#{ENV['JACK_CLIENT_NAME']}_synth:in")
    expect(MB::Sound::FastAudio.jack_connect(dest.output.port, capture.port)).to eq(true)

    # The loopback's own delay: our port read back by our own client, a
    # period late or not depending on the order JACK runs its ports in
    # (measured with a timed probe; the synth's port gets no delay)
    probe = (MB::Sound::FastAudio.jack_frame_time + 4096) & 0xffff_ffff
    dest.output.write_at(probe, 0xfe)
    echo = nil
    deadline = MB::U.clock_now + 2
    echo = capture.read_raw.first until echo || MB::U.clock_now > deadline || !sleep(0.005)
    lag = delta(probe, echo[0])

    # What the destination sends, and the audio clock at that moment
    sent = []
    send_at = dest.method(:send_at)
    dest.define_singleton_method(:send_at) do |s, frame, kind, d1, d2 = 0|
      clock = out.jack_clock
      ahead = frame - s.write_frame
      audio = (clock[:frame_time] + clock[:write_pos] + ahead - clock[:read_pos]) & 0xffff_ffff
      sent << [frame, audio]
      send_at.call(s, frame, kind, d1, d2)
    end

    session.arrangement.track(:hw, dest)
    # (launched a beat in, so the output's queue is flowing: the very
    # first frame's audio can't be early, and its note would be late)
    session.arrangement.play(:hw, clip, start_time: 1/16r)
    done = 0
    while done < frames
      n = [size, frames - done].min
      session.process_buffer(n)
      done += n
    end

    got = []
    deadline = MB::U.clock_now + 3
    while got.length < sent.length && MB::U.clock_now < deadline
      got.concat(capture.read_raw)
      sleep 0.01
    end
    [got.map { |f, b| [delta(lag, f) & 0xffff_ffff, b.bytes] }, sent, dest.output.stats, out.stats, lag]
  end

  it "plays to one of this process's own ports when named (a loopback into the Session's MIDI input)" do
    inp = open(MB::Sound::MIDI::Input.new) # our own midi_in
    dest = MB::Sound.midi_out("#{ENV['JACK_CLIENT_NAME']}:midi_in")
    expect(dest.port.own).to eq(true)
    dest.test(64, length: 0.05)
    got = []
    deadline = MB::U.clock_now + 2
    while got.length < 2 && MB::U.clock_now < deadline
      got.concat(inp.read_raw.map { |_, b| b.bytes })
      sleep 0.01
    end
    expect(got).to eq([[0x90, 64, 100], [0x80, 64, 0]])
  end

  [120, 137].each do |bpm|
    it "sends each note on the JACK frame of its audio plus the offset, exactly, at five buffer sizes (#{bpm} BPM)" do
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3, MB::Sound::D4, nil, MB::Sound::A3, MB::Sound::F3).n32
      offset_frames = 96 # 2 ms
      session_frames = {}
      [128, 256, 400, 512, 1024].each do |size|
        got, sent, mstats, astats, lag = play(clip, size: size, bpm: bpm, offset: 2.ms, frames: 36_000)
        label = "#{bpm} BPM, #{size}-frame buffers (loopback lag #{lag})"
        expect(got.length).to eq(sent.length), label
        expect(sent.length).to eq(14), label # 7 notes on and off
        deltas = got.zip(sent).map { |(jack_frame, _bytes), (_frame, audio)| delta(audio, jack_frame) }
        expect(deltas).to eq([offset_frames] * sent.length), "#{label}: #{deltas.inspect}"
        expect(mstats[:timed_late]).to eq(0), label
        expect(astats[:underruns]).to eq(0), label
        session_frames[size] = sent.map(&:first)
        @opened.reverse_each(&:close)
        @opened.clear
      end

      # The clip's 32nds on the samples holding them (launched on the
      # sample holding a 16th note, from which the clip counts, as audio
      # voices do), the same at every size
      step = Rational(240, bpm) / 32 * 48000
      ons = [0, 1, 2, 3, 4, 6, 7].map { |i| (2 * step).floor + (i * step).floor }
      first = session_frames[128]
      expect(first.values_at(0, 2, 4, 6, 8, 10, 12)).to eq(ons)
      session_frames.each_value { |f| expect(f).to eq(first) }
    end
  end
end
