# pause-tails-1 (the maintainer's UI note, 2026-11-21: "I don't expect
# `pause` to silence ringing effects, just stop the transport and release
# sounding notes"): the transport position stops, notes release on the
# pause sample, held sources fade and keep their place, effects ring out,
# and resume plays on without retriggering.
RSpec.describe(MB::Sound::Session::TransportPause, :aggregate_failures) do
  # 120 BPM at 48 kHz: one bar (a whole note) is 96000 frames
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:null_output) { MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 800) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: null_output, transport: transport, channels: 1, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:set) { session.arrangement }
  let(:fade) { (described_class::FADE_SECONDS * 48000).round }

  after { session.close }

  # Renders exactly +frames+ frames in buffers of +size+ (the last one
  # shorter), so pauses and resumes typed between them land on the same
  # frames at any buffer size.
  def run(frames, size = 800, s: session)
    out = []
    left = frames
    while left > 0
      n = [size, left].min
      out << s.process_buffer(n)[0].dup
      left -= n
    end
    SpecBuffers.join(out)
  end

  def rms(x) = Math.sqrt((x**2).mean)

  # A track whose notes release linearly over a tenth of a second.
  def env_track(name = :a, **opts)
    set.track(name, **opts) { |c| n = c.notes; n.amp_env(0, 0, 1, 0.1, curve: :linear) * 0.5 }
  end

  # One whole-bar note per bar
  let(:c3) { MB::Sound.seq(MB::Sound::C3).n1.loop }

  it 'stops the position and releases a sounding note on the pause sample, the frames rendering on' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    before = run(24000)
    expect(session.pause_transport.to_s).to eq('pause :transport landed 1:2')
    expect(session.transport_paused?).to eq(true)
    frame = session.frame
    data = run(48000)
    expect(transport.position).to eq(1/4r) # (stood still)
    expect(session.frame).to eq(frame + 48000) # (rendered on)
    expect(session.pause_held_frames).to eq(48000)
    expect(session.transport_record[:playing]).to eq(false)
    expect(session.transport_record[:paused]).to eq(true)

    # The release starts on the pause's first sample: a straight line down
    # over 0.1 s from the sustain level, then silence
    pre = before[-1] # (the sustain level)
    expect(data[0]).to eq(pre) # (the release's first step: still at the sustain)
    expect(data[1]).to be < pre
    expect(data[2400] / pre).to be_within(0.01).of(0.5)
    expect(data[4800..].abs.max).to eq(0)
  end

  it 'lets a delay in the track ring out after the pause, with nothing new entering it' do
    env_track(fx: ->(sig) { sig.delay(0.25, feedback: 0.5) })
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(48000)
    session.pause_transport
    data = run(96000)
    # the echoes go on after the note's release (0.1 s) and decay by the
    # feedback each 0.25 s, never louder than the echo before
    slices = (0...8).map { |i| rms(data[(i * 12000)...((i + 1) * 12000)]) }
    expect(slices[1]).to be > 0.05
    expect(slices[1..].each_cons(2).all? { |a, b| b <= a * 0.6 }).to eq(true), slices.inspect
    expect(slices[3]).to be > 0.005
  end

  it 'plays on without retriggering the note it released, the next note on its own time' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(24000)
    session.pause_transport
    run(24000)
    expect(session.play_on.to_s).to eq('play_on :transport landed 1:2')
    expect(session.transport_paused?).to eq(false)
    data = run(96000)
    # silent until the next bar, which is 3/4 of a bar of timeline after
    # the resume (the position moved on from 1:2)
    expect(data[0...72000].abs.max).to eq(0)
    expect(data[72000 + 10].abs).to be > 0.1
    expect(transport.position).to eq(1/4r + 1)
  end

  it 'holds an audio loop in place behind a quick fade and plays on from there' do
    loop_sample = MB::Sound.bounce(1.bar, bpm: 120) { 220.hz.sine.at(0.5) + 331.hz.sine.at(0.25) }
    ref = loop_sample.data(0)
    session.add(loop_sample.follow(:resample), name: :loop, at: :now, fade: 0)
    run(30000)
    session.pause_transport
    held = run(20000)
    session.play_on
    after = run(40000)

    # fades out over `fade` frames while it plays on, then silence
    ramp_out = (Numo::SFloat.new(fade).seq(fade - 1, -1) / fade)
    expect((held[0...fade] - ref[30000...(30000 + fade)] * ramp_out).abs.max).to be < 1e-6
    expect(held[fade..].abs.max).to eq(0)
    # plays on from where the fade out reached, fading in
    ramp_in = Numo::SFloat.new(fade).seq / fade
    at = 30000 + fade
    expect((after[0...fade] - ref[at...(at + fade)] * ramp_in).abs.max).to be < 1e-6
    expect((after[fade...30000] - ref[(at + fade)...(at + 30000)]).abs.max).to be < 1e-6
  end

  it 'holds a source without notes as a whole before its bus effects, which ring out' do
    session.bus(:echo) { |sig| sig.delay(0.1, feedback: 0.5) }
    signal = (Numo::SFloat.new(48000 * 4).seq + 1) / 2**20
    session.add(MB::Sound::ArrayInput.new(data: [signal]), name: :drone, at: :now, fade: 0, send: { echo: 1 })
    run(24000)
    session.pause_transport
    held = run(24000)
    # the bus echoes go on (the delayed copy of what fed it), the source
    # itself fades and holds: from the fade's end only echoes, each a
    # delay time after a stretch of the source, halving
    echo_only = held[fade..]
    expect(rms(held[4800...9600])).to be > 0.01
    expect(rms(held[19200...24000])).to be < rms(held[4800...9600]) * 0.2
    expect(echo_only.abs.max).to be > 0
    session.play_on
    after = run(24000)
    # the source plays on from where its fade reached (exact once the
    # echoes of the fade have gone and the fade in is over: the mix is the
    # source plus its echoes, so compare against a continuous render)
    expect(after[0]).to be_within(1e-6).of(held[-1]) # (only echoes at the resume's first sample: the fade in starts at 0)
  end

  it 'gives the same samples at 800 and 367 frames' do
    renders = [800, 367].map do |size|
      tr = MB::Sound::Sequence::Transport.new(bpm: 120)
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: size)
      s = MB::Sound::Session.new(master_gain: 1, output: out, transport: tr, channels: 1, buffer_size: size, realtime: false, raise_errors: true)
      a = s.arrangement
      a.track(:a, fx: ->(sig) { sig.delay(0.25, feedback: 0.5) }) { |c| n = c.notes; n.amp_env(0, 0, 1, 0.1, curve: :linear) * 0.5 }
      a.scene(:one, a: MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop)
      a.go(:one, on: :now)
      sig = (Numo::SFloat.new(48000 * 4).seq + 1) / 2**20
      s.add(MB::Sound::ArrayInput.new(data: [sig]), name: :drone, at: :now, fade: 0)
      parts = [run(30011, size, s: s)]
      s.pause_transport
      parts << run(40000, size, s: s)
      s.play_on
      parts << run(50000, size, s: s)
      s.close
      SpecBuffers.join(parts)
    end
    expect((renders[0] - renders[1]).abs.max).to be < 1e-6
  end

  it 'keeps tempo-synced LFOs running while paused, and puts them back on the grid with resync' do
    results = [false, true].map do |resync|
      tr = MB::Sound::Sequence::Transport.new(bpm: 120)
      s = MB::Sound::Session.new(master_gain: 1, output: MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 800), transport: tr, channels: 1, buffer_size: 800, realtime: false, raise_errors: true)
      a = s.arrangement
      # a quiet note-driven track whose effect adds a one-bar LFO: the LFO
      # is heard alone once the notes have released
      a.track(:a, fx: ->(sig) { sig + 1.bar.lfo.at(0.5) }) { |c| c.notes.amp_env(0, 0, 1, 0.01) * 1e-4 }
      a.scene(:one, a: MB::Sound.seq(MB::Sound::C3).n1.loop)
      a.go(:one, on: :now)
      before = run(24000, s: s)
      s.pause_transport
      during = run(12000, s: s)
      s.play_on(resync: resync)
      after = run(4800, s: s)
      s.close
      [before, during, after]
    end
    (before, during, plain), (_, _, synced) = results
    # paused: the LFO goes on from where it was (no jump at the pause)
    expect((during[0] - before[-1]).abs).to be < 0.01
    expect(during[11999]).not_to be_within(0.01).of(during[0])
    # without resync it goes on in wall time; with resync it jumps back
    # to the bar grid's phase at the held position (where it was paused)
    expect((plain[0] - during[-1]).abs).to be < 0.01
    expect((synced[10] - before[-1]).abs).to be < 0.01
    expect((synced[10] - plain[10]).abs).to be > 0.05
  end

  it 'lands on a paused transport as a no-op, and a stop typed while paused still stops' do
    env_track
    set.scene(:one, a: c3)
    set.go(:one, on: :now)
    run(8000)
    session.pause_transport
    session.pause_transport
    run(800)
    expect(session.pause_held_frames).to eq(800)
    session.remove(:a, fade: 0)
    run(800)
    expect(session.players).to eq({})
    session.play_on
    session.play_on
    expect(session.transport_paused?).to eq(false)
  end

  describe 'the console commands on a realtime Session' do
    let(:rt) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: :virtual, buffer_size: 256), channels: 1, master_gain: 1, realtime: true, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }

    after do
      rt.close
      MB::Sound.rewind
    end

    def consume(seconds) = MB::Sound::Internal.wait_audio(rt, seconds)
    def within(&block) = MB::Sound::Session.with_context(session: rt, &block)

    it 'pauses with pause, plays on with start (or pause), and freezes with suspend' do
      rt.add(220.hz.sine.at(0.1), name: :drone, at: :now, fade: 0)
      consume(0.1)
      st = within { MB::Sound.pause }
      expect(st.state).to eq(:paused)
      expect(st.to_s).to include('effects ring out')
      consume(0.1)
      expect(rt.transport_paused?).to eq(true)
      expect(MB::Sound::TransportMethods.toggle_line(rt)).to eq('start') # (NAV Space)
      pos = rt.transport.position
      rendered = rt.frames_rendered
      consume(0.1)
      expect(rt.transport.position).to eq(pos)
      expect(rt.frames_rendered).to be > rendered # (renders on while paused)

      st = within { MB::Sound.start }
      expect(st.state).to eq(:resumed)
      consume(0.1)
      expect(rt.transport.position).to be > pos
      expect(within { MB::Sound.pause }.state).to eq(:paused)
      expect(within { MB::Sound.pause }.state).to eq(:resumed) # (pause again plays on)
      consume(0.05)

      st = within { MB::Sound.suspend }
      expect(st.state).to eq(:suspended)
      consume(0.1)
      held = rt.frames_rendered
      consume(0.1)
      expect(rt.frames_rendered).to eq(held) # (the old freeze: nothing renders)
      expect(within { MB::Sound.suspend }.state).to eq(:resumed)
      consume(0.05)
      expect(rt.frames_rendered).to be > held
    end
  end

  it 'shows a paused transport in the transport pane as a pause sign, not a stop' do
    draw = ->(**f) {
      grid = MB::Term::Cells.new(50, 1)
      MB::Sound::UI::Panes::Transport.new.draw(MB::Sound::UI::Canvas.new(grid, 0, 0, 50, 1), MB::Sound::UI::Snapshot.fake(**f), {})
      grid.to_text(:none).lines.first.to_s
    }
    expect(draw.(playing: true)).to start_with('▶ 1:1')
    expect(draw.(playing: false, paused: true)).to start_with('││ 1:1')
    expect(draw.(playing: false)).to start_with('■ 1:1')
  end
end
