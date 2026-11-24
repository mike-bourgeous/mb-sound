# The timing harness of MIDI out on JACK (midi-out-1; destination_jack_spec
# and its slow tier, destination_jack_slow_spec): a Session plays a clip on
# a MIDI out track whose port is looped back (through the private dummy
# JACK server, 256-frame periods) into a JACK MIDI input that records each
# message's JACK frame, and each message is compared with the JACK frame
# where the Session's audio of the message's frame actually left.
#
# Where the audio left is measured, not taken from the clock the
# destination used: the audio gets a click on each note-on's frame, the
# output captures what it played (silence before the first write
# included), and the device clock (#jack_clock's :frames_played and
# :frame_time) maps the captured clicks to JACK frames.  A check against
# the clock read at send time could not see that clock being a period
# early before the first audio left (midi-out-first-note: the first note
# went 256 frames ahead of its audio in 983 of 1000 starts, and that check
# failed only when a cycle landed between its clock read and the
# destination's).  Each message is checked against its own frame's click,
# so a gap in the audio (an underrun, which a busy machine can cause) moves
# the truth of what follows it: notes go with their audio through gaps too
# (midi-out-first-note-2), so a gap doesn't fail a play; plays with one are
# counted and reported after the example.  The output conceals underruns
# with silence unless +conceal:+ says otherwise, so concealment grains can't
# repeat a click.
#
# Usage: include_context 'JACK MIDI out timing' in a describe block.
RSpec.shared_context 'JACK MIDI out timing' do
  env_names = %w[AUDIO_BACKEND OUTPUT_DEVICE INPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE JACK_CLIENT_NAME AUDIO_PROFILE].freeze

  around(:each) do |ex|
    saved = env_names.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }

  before(:each) do
    skip @jack_error if @jack_error
    @gaps = 0
    @plays = 0
    @gap_notes = []
    ENV['AUDIO_BACKEND'] = 'jack'
    ENV['OUTPUT_DEVICE'] = 'none'
    ENV['MIDI_API'] = 'jack'
    ENV['JACK_CLIENT_NAME'] = "mbspec_mo#{rand(1 << 20)}"
    @opened = []
    @synth = MB::Sound::FastMIDI::Input.new(:jack, "#{ENV['JACK_CLIENT_NAME']}_synth", nil, 'in', 1000)
  end

  after(:each) do
    if @gaps.to_i > 0
      RSpec.configuration.reporter.message(
        "#{RSpec.current_example.full_description}: #{@gaps} of #{@plays} plays had a gap in the audio it didn't force " \
        "(underruns), their notes checked against their own audio:\n  #{@gap_notes.join("\n  ")}"
      )
    end
    @opened.reverse_each(&:close)
    @synth&.close
    MB::Sound::MIDI::Destination.close
    MB::Sound::Jack.close
  end

  def open(obj)
    @opened << obj
    obj
  end

  def close_opened
    @opened.reverse_each(&:close)
    @opened.clear
  end

  def delta(a, b)
    ((b - a + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
  end

  # Plays +clip+ on a MIDI out track for +frames+ frames in +size+-frame
  # buffers at +bpm+ with +offset+, launched at +start+ (bars), driving the
  # Session's buffers here (each written to the JACK output, which paces
  # them).  With +phase+, the first buffer is rendered at that frame within
  # the server's 256-frame period.  Returns a Hash: :got, the messages
  # received as [JACK frame (less the loopback's lag), bytes]; :sent, for
  # each message the destination sent, [session frame, JACK frame its audio
  # left on] (see the file comment); the destination's and the output's
  # :mstats and :astats (underruns counted before the queue drains at the
  # end); the loopback's :lag; :steps, each click's played frame minus its
  # session frame (one value when the audio flowed without a gap); :jumps,
  # each gap seen between two clicks as a Hash (:after and :before, the
  # clicks' session frames, :frames, how much later the audio went, and
  # :step, the later click's step); the :phase measured; and with +hold+,
  # :held (false if the hold timed out) and :held_at (the session frame
  # starting the held write).
  #
  # +hold+ makes the Session's writes late on purpose, as a busy machine
  # does: :first holds the first write until a JACK cycle has gone by with
  # the ring still empty (the first notes are already queued by then: sends
  # come while a buffer renders), and an Integer k holds the k-th write
  # (from 0) until the output has run out of audio (an underrun, with notes
  # of that buffer queued before it).  +unannounced+, an Integer k, also
  # holds the k-th write until an underrun but leaves it out of :held and
  # :held_at, as a busy machine makes a gap the check isn't told about
  # (:unannounced_held says whether it happened).
  def play(clip, size:, bpm:, offset:, frames:, start: 1/16r, phase: nil, hold: nil, unannounced: nil, conceal: :silence)
    out = open(MB::Sound::DeviceOutput.new(channels: 1, buffer_size: size, latency: 0.15, adaptive: false, capture: 48000 * 4, conceal: conceal))
    capture = open(MB::Sound::MIDI::Input.new) # our own midi_in: JACK frame times
    session = open(MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: bpm),
                                         channels: 1, buffer_size: size, realtime: false, raise_errors: true))
    dest = MB::Sound.midi_out("#{ENV['JACK_CLIENT_NAME']}_synth", offset: offset)
    expect(dest.port.name).to eq("#{ENV['JACK_CLIENT_NAME']}_synth:in")
    expect(MB::Sound::FastAudio.jack_connect(dest.output.port, capture.port)).to eq(true)

    # The loopback's own delay: our port read back by our own client, a
    # period late or not depending on the order JACK runs its ports in,
    # which can differ between plays (ports are made again for each), so
    # it's measured each time with a timed probe; the synth's port gets no
    # delay
    probe = (MB::Sound::FastAudio.jack_frame_time + 4096) & 0xffff_ffff
    dest.output.write_at(probe, 0xfe)
    echo = nil
    deadline = MB::U.clock_now + 2
    echo = capture.read_raw.first until echo || MB::U.clock_now > deadline || !sleep(0.005)
    lag = delta(probe, echo[0])

    # Each message's session frame, and a click in the audio on each
    # message's frame (sends come while a buffer renders, before it's
    # written)
    sent = []
    clicks = []
    send_at = dest.method(:send_at)
    dest.define_singleton_method(:send_at) do |s, frame, kind, d1, d2 = 0|
      sent << frame
      clicks << frame unless clicks.include?(frame)
      send_at.call(s, frame, kind, d1, d2)
    end
    written = 0
    writes = 0
    held = nil
    held_at = nil
    unannounced_held = nil
    write = out.method(:write)
    out.define_singleton_method(:write) do |data|
      n = data[0].length
      here = clicks.select { |f| f >= written && f < written + n }
      unless here.empty?
        data = data.map(&:dup)
        here.each { |f| data[0][f - written] = 1 }
      end
      if (hold == :first && writes == 0) || hold == writes || unannounced == writes
        deadline = MB::U.clock_now + 2
        if hold == :first && writes == 0
          c0 = out.jack_clock[:frame_time]
          nil until out.jack_clock[:frame_time] != c0 || MB::U.clock_now > deadline || !sleep(0.0002)
        else
          u0 = out.stats[:underruns]
          nil until out.stats[:underruns] != u0 || MB::U.clock_now > deadline || !sleep(0.001)
        end
        if unannounced == writes
          unannounced_held = MB::U.clock_now < deadline
        else
          held = MB::U.clock_now < deadline
          held_at = written
        end
      end
      written += n
      writes += 1
      write.call(data)
    end

    session.arrangement.track(:hw, dest)
    session.arrangement.play(:hw, clip, start_time: start)
    if phase
      deadline = MB::U.clock_now + 1
      nil until ((MB::Sound::FastAudio.jack_frame_time - phase) % 256) < 8 || MB::U.clock_now > deadline
      phase = MB::Sound::FastAudio.jack_frame_time % 256
    end
    done = 0
    while done < frames
      n = [size, frames - done].min
      session.process_buffer(n)
      done += n
    end
    astats = out.stats

    got = []
    deadline = MB::U.clock_now + 3
    while got.length < sent.length && MB::U.clock_now < deadline
      got.concat(capture.read_raw)
      sleep 0.01
    end
    deadline = MB::U.clock_now + 2
    sleep 0.01 while out.stats[:queued] > 0 && MB::U.clock_now < deadline

    # Where each click left: the device clock counts every frame played,
    # so captured frame k left on JACK frame frame_time + k - frames_played
    # (each message by its own frame's click, so a gap in the audio moves
    # what follows it)
    played = out.captured[0]
    found = (0...played.length).select { |k| played[k] > 0.5 }
    expect(found.length).to eq(clicks.length)
    step_of = clicks.zip(found).to_h { |f, k| [f, k && k - f] }
    steps = step_of.values.uniq
    # Where the audio jumps later: a gap (underrun) between two clicks
    jumps = step_of.each_cons(2).filter_map do |(f0, s0), (f1, s1)|
      { after: f0, before: f1, frames: s1 - s0, step: s1 } if s0 && s1 && s1 != s0
    end
    clock = out.jack_clock
    left = ->(f) { (clock[:frame_time] + f + step_of[f] - clock[:frames_played]) & 0xffff_ffff }

    { got: got.map { |f, b| [delta(lag, f) & 0xffff_ffff, b.bytes] }, sent: sent.map { |f| [f, left.(f)] },
      mstats: dest.output.stats, astats: astats, lag: lag, steps: steps, jumps: jumps, phase: phase, held: held, held_at: held_at,
      unannounced_held: unannounced_held }
  end

  # Expects every message of +r+ (see #play) on its own audio's JACK frame
  # plus +offset_frames+, nothing late or still waiting.  With +gap+ (a play
  # whose +hold:+ forced an underrun), expects that gap: the audio jumps
  # later between the last click before the held write and the first click
  # in or after it, by the forced gap's size: with silence concealment the
  # held write's audio starts a JACK period (the output plays from the next
  # cycle after running dry), with the default concealment the jump is
  # frames the concealment filled.  Gaps the play didn't force (underruns of
  # a busy machine; one more often follows the forced one, as the output's
  # queue refills from empty) never fail it, since every message is checked
  # against its own audio (see the file comment): they are counted and
  # printed after the example.
  def expect_on_time(r, offset_frames, label, gap: false)
    jack = MB::Sound::Jack.info
    label = "#{label} (loopback lag #{r[:lag]}, JACK #{jack&.slice(:skipped_cycles, :repeated_cycles)}, audio steps #{r[:steps].inspect})"
    extra = r[:jumps]
    if gap
      forced = r[:jumps].find { |j| j[:after] < r[:held_at] && j[:before] >= r[:held_at] }
      if forced
        extra = r[:jumps] - [forced]
        if r[:astats][:concealed] == 0
          period = jack[:buffer_size]
          expect((r[:held_at] + forced[:step]) % period).to eq(0), "#{label}: the audio after the forced gap (#{forced[:frames]} frames) doesn't start a #{period}-frame JACK period"
        else
          expect(forced[:frames]).to be_between(1, r[:astats][:concealed]), "#{label}: the forced gap jumped #{forced[:frames]} frames, the concealment filled #{r[:astats][:concealed]}"
        end
      else
        expect(forced).not_to be_nil, "#{label}: no gap in the audio across the held write at session frame #{r[:held_at].inspect}, gaps elsewhere: #{r[:jumps].inspect}"
      end
    end
    @plays += 1
    unless extra.empty?
      @gaps += 1
      @gap_notes << "#{label}: unforced gaps #{extra.map { |j| "#{j[:frames]} frames between session frames #{j[:after]} and #{j[:before]}" }.join(', ')}"
    end
    expect(r[:got].length).to eq(r[:sent].length), label
    deltas = r[:got].zip(r[:sent]).map { |(jack_frame, _bytes), (_frame, audio)| delta(audio, jack_frame) }
    expect(deltas).to eq([offset_frames] * r[:sent].length), "#{label}: #{deltas.inspect}"
    expect(r[:mstats][:timed_late]).to eq(0), label
    expect(r[:mstats][:timed_waiting]).to eq(0), label
  end

  # The first notes of a fresh output, swept over where in the JACK period
  # the first buffer renders (+phases+, frames into the period) at each of
  # +sizes+, +rounds+ times, for a two-note clip launched at +start+: each
  # play's messages on time (#expect_on_time).
  def sweep(start, sizes:, phases:, rounds: 1, hold: nil)
    rounds.times do |round|
      sizes.each do |size|
        phases.each do |phase|
          r = play(MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n32, size: size, bpm: 120, offset: 2.ms, frames: 12_000, start: start, phase: phase, hold: hold)
          expect(r[:held]).to eq(true), "the hold (#{hold.inspect}) timed out" if hold
          expect(r[:sent].length).to be >= 3
          expect_on_time(r, 96, "round #{round}, #{size}-frame buffers, launched at #{start} bars, starting at phase #{r[:phase]} of the period")
          close_opened
        end
      end
    end
  end
end
