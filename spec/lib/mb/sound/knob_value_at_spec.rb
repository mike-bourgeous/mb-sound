RSpec.describe(MB::Sound::GraphNode::Knob::ValueAt) do
  # 120 BPM at 48kHz: one bar (a whole note) is 96000 frames
  def new_session(buffer_size = 800)
    out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: buffer_size)
    MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 120), channels: 1, buffer_size: buffer_size, realtime: false, raise_errors: true)
  end

  def render(session, frames, size = 800)
    out = []
    done = 0
    while done < frames
      n = [size, frames - done].min
      out << session.process_buffer(n)[0].dup
      done += n
    end
    SpecBuffers.join(out)
  end

  let(:session) { new_session }
  after { session.close }

  it 'answers queued turns and ramps for future positions, as they render' do
    k = session.knob(:cut, 800, range: 100..8000, curve: :exp, smooth: 0)
    session.add(k * 1, name: :x, on: :now)
    session.turn(:cut, 3000, start_time: 1r)                              # frame 96000
    session.turn(:cut, 200, start_time: 3/2r, over: 1.beat, curve: :smooth) # 144000..168000

    positions = [0r, 1/2r, 1r, 3/2r, 3/2r + 1/32r, 3/2r + 1/8r, 13/8r, 7/4r, 2r]
    predicted = positions.map { |pos| k.value_at(pos) }

    d = render(session, 200_000)
    positions.zip(predicted).each do |pos, v|
      frame = (pos * 96000).to_i
      expect(v).to be_within(v * 1e-6).of(d[frame]), "at #{pos} (frame #{frame})"
    end
  end

  it 'reads positions in the span being rendered exactly' do
    k = session.knob(:cut, 800, range: 100..8000, smooth: 0)
    session.add(k * 1, name: :x, on: :now)
    session.turn(:cut, 2000, start_time: 0r, over: 1.beat)
    seen = []
    tap = MB::Sound::GraphNode::ProcNode.new(k.get_sampler) { |buf|
      span = MB::Sound::Session.span
      seen << [k.value_at(span.pos + 100 * span.per_sample), buf[100]]
      buf
    }
    session.add(tap, name: :y, on: :now)
    render(session, 8000)
    seen.each { |v, s| expect(v).to be_within(1e-3).of(s) }
  end

  it 'never extrapolates a follow and keeps decisions' do
    k = session.knob(:a, 0.25)
    session.knob(:b, 0.75)
    session.add(k * 1, name: :x, on: :now)
    render(session, 800)

    expect(k.value_at(4r)).to eq(0.25)
    session.turn(:a, 0.5, start_time: 4r)
    expect(k.value_at(4r)).to eq(0.25) # decided before the turn
    expect(k.value_at(5r)).to be_within(1e-12).of(0.5)

    session.turn(:a, follow: :b)
    render(session, 800)
    expect(k.value).to eq(0.75)
    expect(k.value_at(3r)).to eq(0.75) # the latest value while following
    expect(k.value_at(6r)).to eq(0.5)  # the turn queued for 4r ends the follow
    expect(session.decision_log.map(&:name)).to all(eq(:a))
    expect(session.decision_log.map(&:pos)).to include(3r, 4r, 5r, 6r)
  end

  describe 'a follow of a tempo LFO (timeline-pure, beats-timing-1)' do
    # 124 BPM: bar lines fall between samples (a bar is 92903.2 frames)
    let(:session) {
      out = MB::Sound::NullOutput.new(channels: 1, sleep: false, buffer_size: 367)
      MB::Sound::Session.new(master_gain: 1, output: out, transport: MB::Sound::Sequence::Transport.new(bpm: 124), channels: 1, buffer_size: 367, realtime: false, raise_errors: true)
    }

    it 'answers the LFO\'s value at any position, rendered or ahead, from where the follow landed' do
      k = session.knob(:e, 0.5, range: 0.0..1.0)
      session.add(k * 1, name: :x, on: :now)
      render(session, 37 * 367, 367)
      lfo = 3.beats.lfo.sine.with_phase(0.1).at(0.2..0.9)
      session.turn(:e, follow: lfo)
      render(session, 367, 367)
      seg = k.instance_variable_get(:@segment)
      expect(seg.pure).to equal(lfo)
      t = seg.time
      expect(t).to be > 0

      # Ahead: the LFO counted from the landing position
      ahead = [t + 1r / 3, t + 5r / 4, t + 3]
      want = ahead.map { |p| MB::Sound::MIDI::Param::Graph.eval(lfo, p - t) }
      expect(ahead.map { |p| k.value_at(p) }).to eq(want)
      expect(session.decision_log_length).to eq(0) # (pure answers aren't decisions)

      # Rendered: the samples (float32) the knob plays
      per = session.transport.whole_notes_per_frame(48000)
      worst = 0.0
      60.times {
        pos0 = session.transport.position
        render(session, 367, 367)
        out = k.instance_variable_get(:@span_out)
        367.times { |i| worst = [worst, (k.value_at(pos0 + per * i) - out[i]).abs].max }
      }
      expect(worst).to be < 1e-6
    end

    it 'answers a square\'s new half on a bar line that falls between samples' do
      k = session.knob(:e, 0.5, range: 0.0..1.0)
      session.add(k * 1, name: :x, on: :now)
      session.turn(:e, follow: 2.bars.lfo.square.at(0.0..1.0))
      render(session, 367, 367)
      expect(k.instance_variable_get(:@segment).time).to eq(0)
      # The frame before bar 2's line still plays the first half...
      d = render(session, 100_000, 367)
      frame = (1r / session.transport.whole_notes_per_frame(48000)).floor
      expect(d[frame - 367]).to eq(1)
      # ...but the knob answers the second half for the bar line itself
      expect(k.value_at(1r)).to eq(0)
      expect(k.value_at(1r - 1r / 1000)).to eq(1)
    end

    it 'leaves follows of other nodes as before (the latest value)' do
      session.knob(:b, 0.75)
      k = session.knob(:a, 0.25)
      session.add(k * 1, name: :x, on: :now)
      session.turn(:a, follow: :b)
      render(session, 800)
      expect(k.instance_variable_get(:@segment).pure).to be_nil
      expect(MB::Sound::GraphNode::Knob.timeline_pure?(2.bars.lfo * 0.5 + 0.25)).to eq(true)
      expect(MB::Sound::GraphNode::Knob.timeline_pure?(session.knob(:b) * 0.5)).to eq(false)
      expect(MB::Sound::GraphNode::Knob.timeline_pure?(0.5.hz.lfo)).to eq(false)
    end
  end

  it 'answers recorded decisions while replaying' do
    k = session.knob(:a, 0.25)
    session.replay_decisions!([[:a, 0, 8r, 0.875]])
    expect(k.value_at(8r)).to eq(0.875)
    expect(k.value_at(9r)).to eq(0.25)
  end

  it 'works as a MIDI::Param in graph arithmetic' do
    k = session.knob(:sw, 0.5, range: 0.5..0.75)
    param = MB::Sound::MIDI::Param.wrap(k * 0.5 + 0.25)
    expect(param.value_at(0r)).to be_within(1e-12).of(0.5)
    expect(MB::Sound::MIDI::Param.wrap(k.get_sampler).value_at(0r)).to eq(0.5)
  end
end
