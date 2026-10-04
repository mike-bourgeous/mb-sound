#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Plays reference synth loads (bin/synths/fm_bass.rb playing a generated
# bass riff, bin/songs/stereo_drone.rb, or both) through the sound card with
# several latency settings, and reports underruns, render load, render
# spikes and garbage collections, and latency for each, to choose latency
# defaults (MB::Sound::DeviceOutput::PROFILES).
#
# Usage: $0 [options]
#
# Examples:
#     $0                                   # the profiles and 400/128/50 with each load (~2 min)
#     $0 --loads fm_bass -s 20             # only the bass
#     $0 --settings default,512/256/30     # profiles or write/period/queue ms
#     $0 --buffers 256,512 --periods 128 --latencies 0,0.02   # a grid of settings
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

# Parses --settings entries: profile names (see DeviceOutput::PROFILES) or
# write/period/queue_ms triples like 400/128/50.  Returns Hashes for
# DeviceOutput.new and a label.
def parse_settings(text)
  text.split(',').map(&:strip).map { |entry|
    if entry.include?('/')
      write, period, queue_ms = entry.split('/').map { |v| Float(v) }
      raise ArgumentError, "Give write/period/queue_ms, not #{entry}" unless queue_ms
      { label: entry, profile: :default, buffer_size: write.to_i, period: period.to_i, latency: queue_ms / 1000.0 }
    else
      profile = entry.delete_prefix(':').to_sym
      raise ArgumentError, "Unknown profile #{entry}" unless MB::Sound::DeviceOutput::PROFILES.include?(profile)
      { label: profile.to_s, profile: profile }
    end
  }
end

# Plays +load+ with +setting+ for +seconds+ after a warmup second, returning
# measurements.
def measure(load, setting, seconds:, midi:, oversample:, rate:, device:, backends:)
  out = MB::Sound::DeviceOutput.new(
    channels: 2, sample_rate: rate, device: device, backends: backends,
    **setting.slice(:profile, :buffer_size, :period, :latency)
  )

  session = MB::Sound::Session.new(output: out, transport: MB::Sound::Sequence::Transport.new, buffer_size: out.buffer_size)
  loads = []
  latencies = []
  peak = 0.0
  spikes = 0
  gc_spikes = 0
  majors = GC.stat(:major_gc_count)
  warm = false

  session.add_tap { |mix|
    count = GC.stat(:major_gc_count)
    gc = count != majors
    majors = count
    next unless warm

    render_load = session.render_load
    loads << render_load
    if render_load > 1
      spikes += 1
      gc_spikes += 1 if gc
    end
    latencies << out.latency
    peak = [peak, *mix.map { |c| c.abs.max }].max
  }

  session.add(MB::Sound.stereo_drone, at: :now) unless load == 'fm_bass'
  session.add(MB::Sound.fm_bass(midi, parameter_map: false, oversample: oversample), at: :now) unless load == 'stereo_drone'

  sleep 1
  warm = true
  underruns = out.underruns
  gc_start = GC.stat(:major_gc_count)
  sleep seconds
  underruns = out.underruns - underruns
  major_gcs = GC.stat(:major_gc_count) - gc_start
  session.close

  {
    label: setting[:label], buffer: out.buffer_size, period: out.period, queue: out.queue_limit, rate: out.sample_rate.round,
    underruns: underruns, peak: peak, spikes: spikes, gc_spikes: gc_spikes, major_gcs: major_gcs,
    load_mean: loads.empty? ? 0 : loads.sum / loads.length, load_p99: percentile(loads, 0.99), load_max: loads.max || 0,
    latency_min: latencies.min || 0, latency_max: latencies.max || 0,
  }
end

MB::Sound.script(
  args: 0,
  loads: ['fm_bass,stereo_drone,both', String, 'Reference loads to play in turn (fm_bass, stereo_drone, both)'],
  settings: ['low,default,400/128/50,safe', String, 'Latency settings: profiles or write/period/queue_ms'],
  buffers: [nil, String, 'Instead of --settings, a grid: write sizes (frames, comma-separated)'],
  periods: ['128,256', String, 'Grid: sound card periods (frames, comma-separated)'],
  latencies: ['0,0.02,0.05', String, 'Grid: queue lengths (seconds; at least two writes each)'],
  seconds: [10.0, '-s', 'Seconds to play each setting', 2.0..600.0],
  oversample: [4, Integer, 'fm_bass oversampling factor (1 for none)', 1..8],
  backend: [nil, String, '-b', 'Backends to try, comma-separated (e.g. jack,pulseaudio)'],
  device: [nil, String, '-d', 'Device index or part of its name'],
  rate: [48000, Integer, '-r', 'Sample rate to ask for', 8000..384000],
) { |_args, p|
  loads = p.loads.split(',').map(&:strip)
  bad = loads - %w[fm_bass stereo_drone both]
  abort "Unknown loads: #{bad.join(', ')} (use fm_bass, stereo_drone, both)" unless bad.empty?

  settings =
    if p.buffers
      list = ->(s, conv) { s.split(',').map { |v| conv.(v.strip) } }
      list.(p.buffers, ->(v) { Integer(v) })
        .product(list.(p.periods, ->(v) { Integer(v) }), list.(p.latencies, ->(v) { Float(v) }))
        .map { |b, per, lat| { label: "#{b}/#{per}/#{(lat * 1000).round}", profile: :default, buffer_size: b, period: per, latency: lat } }
    else
      parse_settings(p.settings)
    end

  backends = MB::Sound::DeviceOutput.backends(p.backend)
  tmpdir = Dir.mktmpdir('audio_load_check')
  index = 0

  puts "#{loads.length} loads x #{settings.length} settings, #{p.seconds} s each, fm_bass oversampled #{p.oversample}x " \
    "(RUBY_THREAD_TIMESLICE=#{ENV['RUBY_THREAD_TIMESLICE'] || 'default'})"

  loads.each do |load|
    puts
    puts "Load: #{load}"

    results = settings.map do |setting|
      # A new file for each setting: MB::Sound.midi_manager reuses the reader
      # (and its clock) for a filename it has seen before.
      midi = File.join(tmpdir, "riff_#{index += 1}.mid")
      write_riff(midi, p.seconds + 2)

      r = measure(load, setting, seconds: p.seconds, midi: midi, oversample: p.oversample, rate: p.rate, device: p.device, backends: backends)

      puts format('%-12s write %4d  period %4d  queue %5d (%5.1f ms)  latency %5.1f..%5.1f ms  ' \
                  'load mean %3d%% p99 %3d%% max %4d%%  spikes %2d (GC %d of %d)  peak %6.1f dB  underruns %d%s',
                  r[:label], r[:buffer], r[:period], r[:queue], r[:queue] * 1000.0 / r[:rate],
                  r[:latency_min] * 1000, r[:latency_max] * 1000,
                  r[:load_mean] * 100, r[:load_p99] * 100, r[:load_max] * 100,
                  r[:spikes], r[:gc_spikes], r[:major_gcs],
                  r[:peak] > 0 ? r[:peak].to_db : -999, r[:underruns],
                  r[:peak] < 1e-4 ? '  <-- silent' : r[:underruns] == 0 ? '' : '  <--')
      r
    end

    clean = results.select { |r| r[:underruns] == 0 }
    if clean.empty?
      puts 'Every setting had underruns.'
    else
      best = clean.min_by { |r| r[:latency_max] }
      puts "Lowest latency with no underruns: #{best[:label]} (#{(best[:latency_min] * 1000).round(1)}.." \
        "#{(best[:latency_max] * 1000).round(1)} ms plus driver and converter delay)"
    end
  end

  puts
  puts 'Spikes are buffers that took longer to render than to play; "GC n of m" counts spikes'
  puts 'in a buffer with a major garbage collection, of m major collections in the run.'
}

