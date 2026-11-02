# Pausing without a click and turning the monitor trim without one
# (play-ui-1: bin/play.rb's Space and volume keys): the output fades out
# and in around a pause, the frames carry on from the exact next sample,
# and a changed trim glides.
RSpec.describe(MB::Sound::Session::PauseFade, :aggregate_failures) do
  # A virtual-clock NullOutput that keeps every buffer it is given.
  let(:out) {
    Class.new(MB::Sound::NullOutput) {
      def written = @written ||= []
      def write(data)
        written << data[0].dup
        super
      end
    }.new(channels: 1, sleep: :virtual, buffer_size: 256)
  }
  let(:session) { MB::Sound::Session.new(output: out, channels: 1, master_gain: 1, realtime: true, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }
  # A ramp with no zeros: sample i is (i + 1) / 2**20
  let(:signal) { (Numo::SFloat.new(48000 * 4).seq + 1) / 2**20 }

  after do
    session.close
    MB::Sound::Session.monitor_gain = 1.0
  end

  def consume(seconds) = MB::Sound::Internal.wait_audio(session, seconds)

  it 'has a transition for every state and request' do
    states = %i[playing fading_out paused fading_in]
    expect(described_class::TRANSITIONS.keys.sort).to eq(states.product(%i[pause play]).sort)
    expect(described_class::TRANSITIONS.values - states).to eq([])
  end

  it 'fades out before the pause and in after it, playing on from the next sample' do
    session.add(MB::Sound::ArrayInput.new(data: [signal]), name: :ramp, at: :now, fade: 0)
    consume(0.1)
    session.paused = true
    consume(0.1)
    expect(session.pause_state).to eq(:paused)
    held = session.frames_rendered
    consume(0.1)
    expect(session.frames_rendered).to eq(held) # nothing renders while paused
    session.paused = false
    consume(0.1)
    expect(session.pause_state).to eq(:playing)

    bufs = out.written
    # The paused buffers are silent; the others, joined, are the signal from
    # its first sample on, faded only where the pause began and ended
    sounding = bufs.reject { |b| b.abs.max == 0 }
    silent_from = bufs.index { |b| b.abs.max == 0 && bufs.index(b).to_i > 0 && bufs[0...bufs.index(b)].any? { |x| x.abs.max > 0 } }
    expect(silent_from).not_to be_nil
    out_buf = bufs[silent_from - 1] # the faded-out buffer
    in_buf = bufs[silent_from..].find { |b| b.abs.max > 0 } # the faded-in buffer
    joined = SpecBuffers.join(sounding)
    start = joined.to_a.index { |v| v > 0 }
    played = joined[start..]
    expect(played.length).to be > 9600
    ref = signal[0...played.length]
    gain = played / ref
    fade = (described_class::FADE_SECONDS * 48000).round
    # exact everywhere but the two fades: the frames carry on across the pause
    exact = (gain - 1).abs.lt(1e-6)
    expect(exact.count_false).to eq(2 * fade)
    # the fade out ends the buffer before the pause at 0, the fade in starts
    # the buffer after it from 0, both straight lines
    expect(out_buf[-1]).to eq(0)
    expect(in_buf[0]).to eq(0)
    k = (gain - 1).abs.ge(1e-6).where
    out_gains = gain[k[0...fade]]
    in_gains = gain[k[fade..]]
    expect((out_gains.diff.to_a.map { |d| (d + 1.0 / fade).abs }.max)).to be < 1e-4
    expect((in_gains.diff.to_a.map { |d| (d - 1.0 / fade).abs }.max)).to be < 1e-4
  end

  it 'glides a changed monitor trim instead of jumping' do
    session.add(MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(48000 * 2) * 0.5]), name: :dc, at: :now, fade: 0)
    consume(0.1)
    before = out.written.length
    MB::Sound::Session.monitor_gain = 0.1
    consume(0.1)
    after = SpecBuffers.join(out.written[before..])
    steps = after.diff.abs
    step = 0.5 / (MB::Sound::Session::MonitorTrim::RAMP_SECONDS * 48000)
    expect(steps.max).to be <= step * 1.001
    expect(after[-1]).to be_within(1e-6).of(0.05)
    k = after.to_a.index { |v| (v - 0.05).abs < 1e-6 }
    expect(k).to be_within(2).of((0.9 / (1.0 / (MB::Sound::Session::MonitorTrim::RAMP_SECONDS * 48000))).ceil)
  end
end
