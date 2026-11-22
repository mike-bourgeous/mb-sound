# The timing proof of MIDI out on JACK (midi-out-1): a Session plays a clip
# on a MIDI out track whose port is looped back into a JACK MIDI input of
# the same client.  Each note must arrive on the JACK frame where the
# Session's audio of the note's frame actually left plus the offset,
# exactly, at any buffer size, tempo, and start phase, and the note's
# session frame must be the clip position's sample (the same at every
# buffer size).  The harness, and how it finds where the audio left:
# spec/support/jack_midi_out_timing.rb; late writes forced as a busy
# machine makes them (the first write after a cycle, an underrun):
# destination_jack_late_spec.rb; the slow tier's statistical start sweep:
# destination_jack_slow_spec.rb.
require_relative '../../../../support/jack_midi_out_timing'

RSpec.describe('MIDI out on JACK (timing)', :aggregate_failures) do
  include_context 'JACK MIDI out timing'

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

  # midi_out makes a new Destination on each call (a console line typed
  # twice, a track and a later `.stats`); every destination aimed at one
  # port shares that port's MIDI::Output (Destination.output_for): one JACK
  # port of ours, one timed queue (so notes of several tracks leave it in
  # frame order), and #stats and #panic of a fresh object reach the port a
  # track plays through (fixes-18: train 12 asked whether a second port opens)
  it 'shares one output, and one JACK port, among destinations aimed at the same port' do
    synth = "#{ENV['JACK_CLIENT_NAME']}_synth:in"
    ours = -> { MB::Sound::FastAudio.jack_ports("^#{Regexp.escape(ENV['JACK_CLIENT_NAME'])}:", true, MB::Sound::FastAudio::JACK_PORT_IS_OUTPUT) }
    a = MB::Sound.midi_out("#{ENV['JACK_CLIENT_NAME']}_synth")
    expect(ours.()).to eq([a.output.port])
    b = MB::Sound.midi_out(synth, channel: 2) # (another spelling of the same port)
    expect(b).not_to equal(a)
    expect(b.output).to equal(a.output)
    expect(ours.()).to eq([a.output.port])
    expect(MB::Sound::MIDI::Destination.outputs.keys).to eq([[:jack, synth]])
    expect(MB::Sound::FastAudio.jack_connections(a.output.port)).to eq([synth])

    got = []
    receive = ->(n) {
      deadline = MB::U.clock_now + 2
      while got.length < n && MB::U.clock_now < deadline
        got.concat(@synth.read.map { |_, bytes| bytes.bytes })
        sleep 0.005
      end
    }
    a.test(60, length: 0.05)
    receive.(2)
    expect(MB::Sound.midi_out(synth).stats).to eq(a.stats)
    MB::Sound.midi_out(synth, channel: 2).panic
    receive.(4)
    expect(got).to eq([[0x90, 60, 100], [0x80, 60, 0], [0xb1, 120, 0], [0xb1, 123, 0]])
    expect(ours.()).to eq([a.output.port])
  end

  [120, 137].each do |bpm|
    it "sends each note on the JACK frame of its audio plus the offset, exactly, at five buffer sizes (#{bpm} BPM)" do
      clip = MB::Sound.seq(MB::Sound::C3, MB::Sound::E3, MB::Sound::G3, MB::Sound::B3, MB::Sound::D4, nil, MB::Sound::A3, MB::Sound::F3).n32
      offset_frames = 96 # 2 ms
      session_frames = {}
      [128, 256, 400, 512, 1024].each do |size|
        r = play(clip, size: size, bpm: bpm, offset: 2.ms, frames: 36_000)
        label = "#{bpm} BPM, #{size}-frame buffers"
        expect(r[:sent].length).to eq(14), label # 7 notes on and off
        expect_on_time(r, offset_frames, label)
        session_frames[size] = r[:sent].map(&:first)
        close_opened
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

  # The first notes go out before the first audio has left: the output's
  # ring is empty until the first write, and a Session renders its first
  # buffers faster than JACK plays them, so these notes are queued before
  # any cycle has taken audio (midi-out-first-note: one period early, 256
  # frames, in 983 of 1000 starts before the fix).  Swept over where in the
  # JACK period the first buffer renders, for a note on the very first
  # frame and one a 16th in.
  { 'the first frame' => 0r, 'a 16th in' => 1/16r }.each do |where, start|
    it "sends the first notes with their audio at any start phase, for a note on #{where}" do
      sweep(start, sizes: [128, 1024], phases: [0, 64, 128, 192])
    end
  end
end
