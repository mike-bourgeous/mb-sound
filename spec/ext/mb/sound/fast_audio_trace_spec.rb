# The dropout trace (FastAudio::Playback#trace_start, for
# MB::Sound::DropoutProbe) on miniaudio's null device.
RSpec.describe('MB::Sound::FastAudio::Playback dropout trace', :aggregate_failures) do
  let(:rate) { 48000 }

  def open_playback(queue: 2048)
    MB::Sound::FastAudio::Playback.new([:null], -1, 'mb-sound-spec', 1, 2, rate, 0, 0, queue, 0, 2, false, 0).tap { |p| @playbacks << p }
  end

  def wait_until(timeout: 3)
    deadline = MB::U.clock_now + timeout
    sleep 0.002 until yield || MB::U.clock_now > deadline
  end

  before { @playbacks = [] }
  after { @playbacks.each(&:close) }

  it 'is off and empty until started, and checks its sizes' do
    pb = open_playback
    expect(pb.trace?).to eq(false)
    expect(pb.trace_stats).to be_nil
    expect(pb.trace_drain).to eq([[], []])
    expect { pb.trace_start(0, 10) }.to raise_error(ArgumentError, /1 to 16777216/)
    expect(pb.trace_start(100, 10)).to eq(true)
    expect(pb.trace?).to eq(true)
    pb.trace_stop
    expect(pb.trace?).to eq(false)
    pb.write([Numo::SFloat.zeros(256)])
    expect(pb.trace_drain).to eq([[], []])
  end

  it 'records each write and each counted underrun with its times and the queue' do
    pb = open_playback
    pb.trace_start
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    chunk = [Numo::SFloat.new(512).fill(0.1)]
    8.times { pb.write(chunk) } # (fills the 2048-frame queue, then waits for room)
    before = pb.stats[:underruns]
    wait_until { pb.stats[:underruns] > before } # runs dry
    sleep 0.02 # (a few dry pulls)
    pb.write(chunk) # ends the gap
    wait_until { pb.trace_stats[:gap_open] == false && pb.stats[:queued] < 400 }
    writes, gaps = pb.trace_drain

    expect(writes.length).to eq(9)
    writes.each do |enter, exit, wait, room, back, pull, cpu_enter, cpu_exit, queued, limit, frames|
      expect(enter).to be >= t0
      expect(exit).to be >= enter
      expect(frames).to eq(512)
      expect(limit).to eq(2048)
      expect(queued).to be_between(0, 2048)
      expect(cpu_exit).to be >= cpu_enter
      next if wait == 0

      expect(room).to be_between(enter, exit)
      expect(back).to be_between(room, exit)
      expect(pull).to be <= room
      expect(wait).to be <= exit - enter
    end
    expect(writes.count { |w| w[2] > 0 }).to be >= 3 # (writes 5-8 waited)

    expect(gaps.length).to be >= 1
    start, stop, since, frames, available, short, pulls, limit, write_pos, underrun, late, late_at = gaps.last
    expect(stop).to be >= start
    expect(start).to be > writes[7][1]
    expect(since).to be >= 0
    expect(available).to be < frames
    expect(short).to be >= frames - available
    expect(pulls).to be >= 1
    expect(limit).to eq(2048)
    expect(write_pos).to eq(8 * 512)
    expect(underrun).to eq(before + 1)
    expect(late).to be >= since
    expect(late_at).to be <= start

    s = pb.trace_stats
    expect(s).to include(on: true, write_lost: 0, gap_lost: 0)
    expect(s[:pulls]).to be > 10
    expect(s[:period_ns]).to be > 0
    expect(s[:max_pull_gap_ns]).to be > 0
  end

  it 'counts records a full ring drops' do
    pb = open_playback(queue: 8192)
    pb.trace_start(16, 16)
    20.times { pb.write([Numo::SFloat.zeros(64)]) }
    writes, = pb.trace_drain
    expect(writes.length).to eq(16)
    expect(pb.trace_stats[:write_lost]).to eq(4)
  end
end
