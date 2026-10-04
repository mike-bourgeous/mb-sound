#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Checks sound card output through miniaudio (MB::Sound::DeviceOutput):
# prints the backend, device, sample rate, period, queue size, and latency,
# plays a click track (left, right, both, both), and reports underruns and
# the sound card's clock drift against the wall clock.
#
# Usage: $0 [options]
#
# Examples:
#     $0                          # default device for 5 seconds
#     $0 --list                   # backends and devices
#     $0 -d 'MacBook' -s 10       # a device by part of its name
#     $0 --latency 0.03 --busy    # small queue while Ruby is kept busy
#     $0 --buffer 256 --period 128 --latency 0.001   # lowest latency that keeps up?
#     AUDIO_BACKEND=jack $0       # Linux: only JACK (jackd or PipeWire)
#     AUDIO_BACKEND=null $0       # no sound card (miniaudio's null device)
#
# The environment variables in MB::Sound::DeviceOutput (AUDIO_BACKEND,
# OUTPUT_DEVICE, AUDIO_SAMPLE_RATE, AUDIO_LATENCY, AUDIO_PERIOD,
# JACK_CLIENT_NAME) take precedence over these options.

require 'bundler/setup'
require 'mb-sound'

# Renders the click track: a short decaying 1 kHz click every +interval+
# seconds, cycling left, right, both, both.
class ClickTrack
  PATTERN = [[1, 0], [0, 1], [1, 1], [1, 1]].freeze

  def initialize(sample_rate:, interval:, gain:)
    @rate = sample_rate
    @period = (interval * sample_rate).round
    click_length = (0.03 * sample_rate).round
    t = Numo::SFloat.new(click_length).seq / sample_rate
    @click = Numo::NMath.sin(t * 2 * Math::PI * 1000) * Numo::NMath.exp(-t * 150) * gain
    @frame = 0
  end

  def next_buffer(frames)
    l = Numo::SFloat.zeros(frames)
    r = Numo::SFloat.zeros(frames)

    frames.times do |i|
      pos = (@frame + i) % @period
      next if pos >= @click.length
      left, right = PATTERN[((@frame + i) / @period) % PATTERN.length]
      l[i] = @click[pos] * left
      r[i] = @click[pos] * right
    end

    @frame += frames
    [l, r]
  end
end

MB::Sound.script(
  args: 0,
  seconds: [5.0, '-s', 'Seconds to play the click track', 0.1..3600],
  list: [false, '-l', 'List backends and devices, then exit'],
  backend: [nil, String, '-b', 'Backends to try, comma-separated (e.g. jack,pulseaudio)'],
  device: [nil, String, '-d', 'Device index or part of its name'],
  rate: [48000, Integer, '-r', 'Sample rate of the clicks', 8000..384000],
  device_rate: [nil, Integer, 'Sample rate to open the sound card at (default: --rate)', 8000..384000],
  resample: ['fastest', String, 'Resampler when the card runs at another rate', %w[fastest medium best linear zoh off]],
  set_device_rate: [false, "Let CoreAudio change the card's system-wide rate (macOS)"],
  profile: [nil, String, 'Latency profile (default: AUDIO_PROFILE or default)', %w[low default video safe]],
  latency: [nil, Float, 'Seconds queued ahead of the sound card (overrides the profile)', 0.0..2.0],
  period: [nil, Integer, 'Sound card period in frames (overrides the profile)', 16..16384],
  buffer: [nil, Integer, 'Frames per write, the block size a Session renders (overrides the profile)', 16..16384],
  gain: [-12.0, Float, '-g', 'Click level in dB', -60.0..0.0],
  interval: [0.5, Float, 'Seconds between clicks', 0.05..5.0],
  busy: [false, 'Keep another Ruby thread busy (allocating, GC) to test dropouts'],
  busy_priority: [0, Integer, 'Ruby priority of the --busy thread (negative shortens its time slices)', -3..3],
) { |_args, p|
  backends = MB::Sound::DeviceOutput.backends(p.backend)

  puts "miniaudio #{MB::Sound::FastAudio::MINIAUDIO_VERSION}"
  puts "Enabled backends: #{MB::Sound::FastAudio.enabled_backends.join(', ')}"
  puts "Trying: #{backends ? backends.join(', ') : "miniaudio's default order"}"

  begin
    list = MB::Sound::FastAudio.devices(backends, MB::Sound::DeviceOutput.client_name)
  rescue MB::Sound::FastAudio::Error => e
    abort "#{e.message}\n(AUDIO_BACKEND=null tests without a sound card)"
  end

  puts "Backend: #{list[:backend]}"
  puts 'Playback devices:'
  list[:playback].each { |d| puts "  #{d[:index]}: #{d[:name]}#{' (default)' if d[:default]}" }
  puts 'Capture devices:'
  list[:capture].each { |d| puts "  #{d[:index]}: #{d[:name]}#{' (default)' if d[:default]}" }
  next if p.list

  out = MB::Sound::DeviceOutput.new(
    channels: 2, sample_rate: p.rate, device: p.device, profile: p.profile,
    latency: p.latency, period: p.period, buffer_size: p.buffer,
    device_rate: p.device_rate, resample: p.resample, set_device_rate: p.set_device_rate,
    backends: backends
  )

  # Sound card frames (period, queue) are at the card's rate; writes are at
  # the written rate
  ms = ->(frames) { (frames * 1000.0 / out.device_rate).round(1) }
  puts
  puts "Opened: #{out.inspect}"
  puts "  JACK client name: #{MB::Sound::DeviceOutput.client_name}" if out.backend == :jack
  puts "  sample rate: #{out.sample_rate.round} Hz (asked for #{p.rate})"
  puts "  sound card rate: #{out.device_rate.round} Hz#{out.resampling? ? " (resampling: #{p.resample})" : ''}"
  puts "  period: #{out.period} frames (#{ms.(out.period)} ms)"
  puts "  queue limit: #{out.queue_limit} frames (#{ms.(out.queue_limit)} ms)"
  puts "  write size: #{out.buffer_size} frames (#{(out.buffer_size * 1000.0 / out.sample_rate).round(1)} ms)"
  puts "  latency now: #{(out.latency * 1000).round(1)} ms (queue + sound card buffer)"
  puts

  busy = nil
  if p.busy
    puts "Keeping another Ruby thread busy (priority #{p.busy_priority}, " \
      "RUBY_THREAD_TIMESLICE=#{ENV['RUBY_THREAD_TIMESLICE'] || 'default'})"
    busy = Thread.new do
      Thread.current.priority = p.busy_priority
      loop do
        Array.new(20000) { |i| i.to_s * 3 }
        GC.start if rand < 0.05
      end
    end
  end

  clicks = ClickTrack.new(sample_rate: out.sample_rate, interval: p.interval, gain: p.gain.db)
  total = (p.seconds * out.sample_rate).round
  written = 0
  start = MB::U.clock_now
  next_report = 1
  latencies = []
  snapshots = [] # [wall clock, frames played] once a second, for drift

  puts 'Clicks: left, right, both, both...'
  while written < total
    frames = [out.buffer_size, total - written].min
    out.write(clicks.next_buffer(frames))
    written += frames
    latencies << out.latency

    now = MB::U.clock_now
    if now - start >= next_report
      next_report += 1
      s = out.stats
      snapshots << [now, s[:frames_played]]
      puts format('%5.1f s  queued %6.1f ms  latency %6.1f ms  underruns %d',
                  now - start, ms.(s[:queued]), out.latency * 1000, s[:underruns])
    end
  end

  # Underruns before the end of the clicks (the end itself may count one)
  underruns = out.underruns

  # Let the queue play out
  sleep 0.01 until out.stats[:queued] == 0 || MB::U.clock_now - start > p.seconds + 2
  elapsed = MB::U.clock_now - start
  busy&.kill

  puts
  puts "Played #{(written / out.sample_rate).round(2)} s in #{elapsed.round(2)} s"
  puts "Latency: #{(latencies.min * 1000).round(1)}..#{(latencies.max * 1000).round(1)} ms " \
    '(queue + sound card buffer; excludes driver and converter delay)'
  puts "Underruns while playing: #{underruns}"
  puts "Largest sound card request: #{out.stats[:max_callback]} frames (period #{out.period})"

  if snapshots.length >= 2
    (t0, f0), (t1, f1) = snapshots.first, snapshots.last
    device = (f1 - f0) / out.device_rate
    puts "Sound card clock vs wall clock: #{((device - (t1 - t0)) / (t1 - t0) * 1e6).round} ppm over #{(t1 - t0).round(1)} s" \
      "#{' (rough; the clock moves a period at a time, so use -s 30 or more)' if t1 - t0 < 20}"
  end

  out.close
}
