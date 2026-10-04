#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Plays a reference synth load (bin/synths/fm_bass.rb playing a generated
# bass riff, plus bin/songs/stereo_drone.rb) through the sound card with
# several write sizes, sound card periods, and queue lengths, and reports
# underruns, render load, and latency for each, to choose latency defaults.
#
# Usage: $0 [options]
#
# Examples:
#     $0                                   # every combination, 10 s each
#     $0 --load fm_bass -s 20              # only the bass
#     $0 --buffers 256 --periods 128 --latencies 0.001,0.01,0.02
#     AUDIO_BACKEND=null $0 -s 3           # no sound card
#
# Listen too: each setting plays the riff and drone for --seconds, and
# glitches mean underruns.  Underruns are counted after a warmup second.

require 'bundler/setup'
require 'mb-sound'
require 'midilib'
require 'tmpdir'

load File.expand_path('synths/fm_bass.rb', __dir__)
load File.expand_path('songs/stereo_drone.rb', __dir__)

# Writes a bass riff MIDI file at 120 BPM: sixteenth notes (some tied for
# overlapping voices) with the mod wheel sweeping, for +seconds+.
def write_riff(path, seconds)
  seq = MIDI::Sequence.new
  tempo = MIDI::Track.new(seq)
  tempo.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(120))
  seq.tracks << tempo

  track = MIDI::Track.new(seq)
  seq.tracks << track

  step = seq.ppqn / 4
  notes = [28, 28, 40, 28, 31, 28, 43, 33, 28, 28, 40, 28, 35, 36, 38, 40] # E1 riff
  steps = (seconds * 8).ceil # sixteenths at 120 BPM

  steps.times do |i|
    t = i * step
    note = notes[i % notes.length]
    length = i % 8 == 7 ? step * 2 : (step * 0.8).round # some overlap

    on = MIDI::NoteOn.new(0, note, 90 + (i * 7) % 37, 0)
    on.time_from_start = t
    off = MIDI::NoteOff.new(0, note, 0, 0)
    off.time_from_start = t + length
    cc = MIDI::Controller.new(0, 1, ((Math.sin(i * 0.05) + 1) * 63).round, 0)
    cc.time_from_start = t
    track.events.push(cc, on, off)
  end

  track.sort
  track.recalc_delta_from_times
  File.open(path, 'wb') { |f| seq.write(f) }
end

def percentile(values, p)
  return 0 if values.empty?
  sorted = values.sort
  sorted[((sorted.length - 1) * p).round]
end

MB::Sound.script(
  args: 0,
  load: ['both', String, 'Reference load', %w[both fm_bass stereo_drone]],
  seconds: [10.0, '-s', 'Seconds to play each setting', 2.0..600.0],
  buffers: ['256,512,800', String, 'Write sizes to try (frames, comma-separated)'],
  periods: ['128,256', String, 'Sound card periods to try (frames, comma-separated)'],
  latencies: ['0.001,0.02,0.05', String, 'Queue lengths to try (seconds; at least two writes each)'],
  backend: [nil, String, '-b', 'Backends to try, comma-separated (e.g. jack,pulseaudio)'],
  device: [nil, String, '-d', 'Device index or part of its name'],
  rate: [48000, Integer, '-r', 'Sample rate to ask for', 8000..384000],
  oversample: [4, Integer, 'fm_bass oversampling factor (1 for none)', 1..8],
) { |_args, p|
  list = ->(s, conv) { s.split(',').map { |v| conv.(v.strip) } }
  buffers = list.(p.buffers, ->(v) { Integer(v) })
  periods = list.(p.periods, ->(v) { Integer(v) })
  latencies = list.(p.latencies, ->(v) { Float(v) })
  backends = MB::Sound::DeviceOutput.backends(p.backend)

  tmpdir = Dir.mktmpdir('audio_load_check')
  combos = buffers.product(periods, latencies)

  puts "Load: #{p.load}; #{combos.length} settings, #{p.seconds} s each, fm_bass oversampled #{p.oversample}x " \
    "(RUBY_THREAD_TIMESLICE=#{ENV['RUBY_THREAD_TIMESLICE'] || 'default'})"
  puts

  results = combos.each_with_index.map do |(buffer, period, latency), index|
    # A new file for each setting: MB::Sound.midi_manager reuses the reader
    # (and its clock) for a filename it has seen before.
    midi = File.join(tmpdir, "riff_#{index}.mid")
    write_riff(midi, p.seconds + 2)

    out = MB::Sound::DeviceOutput.new(
      channels: 2, sample_rate: p.rate, device: p.device, backends: backends,
      buffer_size: buffer, period: period, latency: latency
    )

    session = MB::Sound::Session.new(output: out, transport: MB::Sound::Sequence::Transport.new, buffer_size: buffer)
    loads = []
    latencies_seen = []
    peak = 0.0
    warm = false
    session.add_tap { |mix|
      next unless warm
      loads << session.render_load
      latencies_seen << out.latency
      peak = [peak, *mix.map { |c| c.abs.max }].max
    }

    session.add(MB::Sound.stereo_drone, at: :now) unless p.load == 'fm_bass'
    session.add(MB::Sound.fm_bass(midi, parameter_map: false, oversample: p.oversample), at: :now) unless p.load == 'stereo_drone'

    sleep 1
    warm = true
    underruns = out.underruns
    sleep p.seconds
    underruns = out.underruns - underruns
    session.close

    result = {
      buffer: buffer, period: out.period, queue: out.queue_limit, rate: out.sample_rate.round,
      underruns: underruns, seconds: p.seconds, peak: peak,
      load_mean: loads.empty? ? 0 : loads.sum / loads.length, load_p99: percentile(loads, 0.99), load_max: loads.max || 0,
      latency_min: latencies_seen.min || 0, latency_max: latencies_seen.max || 0,
    }

    puts format('write %4d  period %4d  queue %5d (%5.1f ms)  latency %5.1f..%5.1f ms  ' \
                'load mean %3d%% p99 %3d%% max %3d%%  peak %6.1f dB  underruns %d%s',
                buffer, result[:period], result[:queue], result[:queue] * 1000.0 / result[:rate],
                result[:latency_min] * 1000, result[:latency_max] * 1000,
                result[:load_mean] * 100, result[:load_p99] * 100, result[:load_max] * 100,
                peak > 0 ? peak.to_db : -999, underruns, peak < 1e-4 ? '  <-- silent' : underruns == 0 ? '' : '  <--')
    result
  end

  clean = results.select { |r| r[:underruns] == 0 }
  puts
  if clean.empty?
    puts 'Every setting had underruns; try larger --buffers, --periods, or --latencies.'
  else
    best = clean.min_by { |r| r[:latency_max] }
    puts "Lowest latency with no underruns: write #{best[:buffer]}, period #{best[:period]}, " \
      "queue #{best[:queue]} frames (#{(best[:latency_min] * 1000).round(1)}..#{(best[:latency_max] * 1000).round(1)} ms " \
      "plus driver and converter delay)"
  end
}
