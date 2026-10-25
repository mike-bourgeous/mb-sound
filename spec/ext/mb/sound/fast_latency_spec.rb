require 'shellwords'

RSpec.describe('MB::Sound::FastLatency', :aggregate_failures) do
  let(:fast) { MB::Sound::FastLatency }
  let(:hist) { MB::Sound::LatencyProbe::Histogram }

  # Probes started by an example, stopped after it.
  let(:probes) { [] }

  def probe(**opts)
    p = fast::Probe.new({ period_ns: 1_000_000, threshold_ns: 2_000_000 }.merge(opts))
    probes << p
    p
  end

  after do
    probes.each(&:stop)
  end

  # Waits up to +timeout+ seconds for the block to be truthy.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_latency.so', __dir__)
    code = 'GC.stress = true; require ARGV[0]; f = MB::Sound::FastLatency; x = f.bucket(12345); p = f::Probe.new({ period_ns: 1_000_000 }); p.start; sleep 0.01; p.stop; d = p.drain; GC.stress = false; p x, d.length > 0'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last(2).map(&:strip)).to eq([hist.bucket(12345).to_s, 'true']), out
  end

  describe '.bucket and .bucket_floor' do
    VALUES = (
      (0..40).to_a +
      (0..43).flat_map { |e| [2**e - 1, 2**e, 2**e + 1] } +
      [123_456_789, 2_000_000, 80_000_000, 10**12, 2**62, -5]
    ).freeze

    it 'match the Ruby reference (Histogram.bucket)' do
      rng = Random.new(42)
      values = VALUES + Array.new(2000) { rng.rand(2**rng.rand(1..45)) }
      values.each do |v|
        expect(fast.bucket(v)).to eq(hist.bucket(v)), "bucket(#{v})"
      end
    end

    it 'put every value in a bucket whose floor and width hold it' do
      VALUES.select { |v| v >= 0 && v < 2**41 }.each do |v|
        i = hist.bucket(v)
        expect(fast.bucket_floor(i)).to eq(hist.floor(i))
        expect(hist.floor(i)).to be <= v
        expect(v).to be < hist.floor(i) + hist.width(i)
      end
    end

    it 'has contiguous, increasing buckets' do
      (1...fast::BUCKETS).each do |i|
        expect(hist.floor(i)).to eq(hist.floor(i - 1) + hist.width(i - 1)), "bucket #{i}"
      end
      expect(fast::BUCKETS).to eq(hist::BUCKETS)
      expect(hist.bucket(2**60)).to eq(fast::BUCKETS - 1)
    end

    it 'buckets are at most 1/16 of their values wide above 16 ns' do
      (16...fast::BUCKETS).each do |i|
        expect(hist.width(i).to_f / hist.floor(i)).to be <= 1.0 / 16
      end
    end
  end

  describe '.percentile' do
    it 'matches the Ruby reference' do
      rng = Random.new(7)
      20.times do
        counts = Array.new(fast::BUCKETS, 0)
        rng.rand(1..50).times { counts[rng.rand(fast::BUCKETS)] += rng.rand(1..1000) }
        [0.0, 0.01, 0.5, 0.9, 0.99, 0.999, 1.0].each do |q|
          expect(fast.percentile(counts, q)).to eq(hist.percentile(counts, q)), "q #{q}"
        end
      end
      expect(fast.percentile(Array.new(fast::BUCKETS, 0), 0.5)).to eq(0)
    end
  end

  describe 'Probe' do
    it 'starts, reports seconds, and stops' do
      p = probe(memory_bytes: 1 << 20, memory_touch: 16_384, cpu_iterations: 1000)
      expect(p.running?).to eq(false)
      p.start
      expect(p.running?).to eq(true)
      expect { p.start }.to raise_error(RuntimeError, /already started/)

      wait_until(timeout: 10) { p.stats[:calibrated] }
      p.stop
      expect(p.running?).to eq(false)

      s = p.stats
      expect(s[:ticks]).to be >= fast::CALIBRATION_TICKS
      expect(s[:memory_base_ns]).to be > 0
      expect(s[:cpu_base_ns]).to be > 0
      expect(s[:priority]).to be_a(String)
      expect(s[:overflow]).to eq(0)

      recs = p.drain
      seconds = recs.select { |r| r[:kind] == :second }
      expect(seconds).not_to be_empty
      expect(seconds.sum { |r| r[:ticks] }).to eq(s[:ticks])
      expect(seconds.last.keys).to include(:late_p99_ns, :mem_p50_ns, :cpu_max_ns, :thread_cpu_ns, :migrations)
      expect(p.histogram(:late).sum).to eq(s[:ticks])
      expect(p.histogram(:memory).sum).to eq(s[:ticks])
      expect(p.histogram(3)).to eq(p.histogram(:stall))
      expect { p.histogram(:nope) }.to raise_error(ArgumentError)
    end

    it 'makes events and episodes for ticks over the threshold' do
      p = probe(threshold_ns: 0, events_per_second: 5, gap_ns: 1_000_000_000)
      p.start
      wait_until(timeout: 10) { p.stats[:ticks] >= 20 }
      p.stop

      s = p.stats
      recs = p.drain
      ticks = recs.select { |r| r[:kind] == :tick }
      episodes = recs.select { |r| r[:kind] == :episode }
      expect(s[:over]).to eq(s[:ticks])
      expect(ticks.length).to eq(s[:events])
      expect(s[:events] + s[:dropped]).to eq(s[:over])
      expect(ticks.length).to be <= 5 * recs.count { |r| r[:kind] == :second }
      expect(episodes.length).to be >= 1
      expect(episodes.sum { |e| e[:over] }).to eq(s[:over])
      expect(ticks.first[:wall_ns]).to be_within(60e9).of(Time.now.to_f * 1e9)
    end

    it 'never blocks on a full ring: overflow is counted and ticks go on' do
      p = probe(threshold_ns: 0, events_per_second: 1_000_000, ring: 4)
      p.start
      wait_until(timeout: 10) { p.stats[:overflow] > 50 }
      before = p.stats[:ticks]
      wait_until(timeout: 10) { p.stats[:ticks] >= before + 50 }
      p.stop

      s = p.stats
      expect(s[:ring]).to eq(4)
      expect(s[:queued]).to eq(4)
      expect(p.drain.length).to eq(4)
      expect(p.drain).to eq([])
    end

    it 'keeps waking on time while a Ruby thread holds the GVL' do
      p = probe
      p.start
      wait_until(timeout: 10) { p.stats[:ticks] > 10 }
      t0 = fast.mono_ns
      fast.spin(0.3)
      held = fast.mono_ns - t0
      ticks = p.stats[:ticks]
      p.stop

      expect(held).to be >= 300_000_000
      # About one tick per ms went on during the 300 ms hold
      expect(ticks).to be > 200
      expect(p.stats[:max_late_ns]).to be < 100_000_000
    end

    it 'wakes a waiting consumer for new records, and wait times out' do
      p = probe
      p.start
      t = Time.now
      expect(p.wait(3)).to eq(true) # the first second's record
      expect(Time.now - t).to be < 2.5
      p.drain
      expect(p.wait(0)).to eq(false).or eq(true)
      p.stop
    end

    it 'lets Thread#kill interrupt #wait' do
      p = probe(period_ns: 100_000_000)
      p.start
      p.drain
      th = Thread.new { p.wait(30) }
      wait_until(timeout: 5) { th.status == 'sleep' || th.status == false }
      t = Time.now
      th.kill
      th.join
      expect(Time.now - t).to be < 1
    end

    it 'rejects bad options' do
      expect { fast::Probe.new({ period_ns: 5 }) }.to raise_error(ArgumentError, /period_ns/)
      expect { fast::Probe.new({ rt_priority: 200 }) }.to raise_error(ArgumentError, /rt_priority/)
    end
  end

  it '.system_sample reports the load average' do
    s = fast.system_sample
    expect(s[:load1]).to be_a(Float)
    if RUBY_PLATFORM.include?('darwin')
      expect(s[:mem_available]).to be > 0
      expect(s[:cpu_idle]).to be > 0
    end
  end
end
