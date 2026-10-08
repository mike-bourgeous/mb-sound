#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures the loudness of audio files per ITU-R BS.1770-4 / EBU R 128:
# integrated loudness (LUFS), short-term (3 s) and momentary (400 ms)
# maxima, loudness range (LRA, EBU Tech 3342), and true peak (dBTP).
# Optionally shows the gain each file needs for loudness targets, and
# writes copies normalized to a target.
#
# Usage: $0 [options] FILE_OR_DIR [...]
#
# Directories are searched recursively for audio files.  Files are read at
# their own sample rate.  Channel weights follow the channel count
# (ffmpeg/SMPTE order: L R C LFE Ls Rs; LFE excluded, surrounds +1.5 dB);
# mono files read 3 LU below the same signal on both stereo channels, as
# the standard says.  Audio shorter than the 400 ms / 3 s windows is
# measured as if padded with silence.
#
# Targets are numbers of LUFS or names from MB::Sound::Loudness::TARGETS
# (--targets lists them with their sources; some are marked "reported,
# unverified"): ebu_r128 (-23), atsc_a85 (-24), spotify (-14),
# spotify_loud (-11), spotify_quiet (-19), apple_music, youtube,
# amazon_music, soundcloud.
#
# Examples:
#     $0 tmp/listening                       # table of every file
#     $0 -t spotify,ebu_r128 tmp/listening   # plus the gain to reach each target
#     $0 --json song.flac                    # JSON (add --series for M/S curves)
#     $0 --markdown tmp/listening/*/         # Markdown table (for notes)
#     $0 -n spotify song.flac                # writes song_spotify.flac at -14 LUFS
#     $0 -n -16 -o loud.flac quiet.flac      # normalized copy with a name
#     $0 -n ebu -o out_dir/ a.flac b.flac    # copies into a directory
#     $0 --targets                           # list the target presets
#
# Normalizing only applies gain (no limiter).  When the copy's true peak
# would be above the target's ceiling (-1 dBTP for numbers), a warning is
# printed, or with --reduce the gain stops at the ceiling.  In the gain
# columns a "!" marks gains that would pass the ceiling.  Same-name files
# are kept unless -f is given.
#
# In the console (bin/sound.rb): loudness('song.flac').lufs, a live meter
# on anything playing (m = song.loudness_meter; bg m; m.to_s), or
# render('song.flac', ..., loudness: :spotify).

require 'bundler/setup'
require 'json'
require 'fileutils'
require 'mb-sound'

AUDIO_EXTENSIONS = %w[flac wav ogg opus mp3 m4a aac aif aiff caf].freeze

# Expands directories into the audio files below them, sorted.
def audio_files(paths)
  paths.flat_map { |p|
    if File.directory?(p)
      Dir.glob(File.join(p, '**', '*')).select { |f| File.file?(f) && AUDIO_EXTENSIONS.include?(File.extname(f).delete('.').downcase) }.sort
    elsif File.file?(p)
      [p]
    else
      raise ArgumentError, "Not found: #{p}"
    end
  }
end

# Formats a level for the table (-inf for silence, n/a for nil).
def level(v)
  return 'n/a' if v.nil?
  v.finite? ? format('%.1f', v) : '-inf'
end

# A short label for a target (its key or number), for file names and columns.
def target_label(target)
  target.key ? target.key.to_s : format('%glufs', target.lufs)
end

# The default name of a normalized copy, e.g. song_spotify.flac or
# song_-14lufs.flac.
def normalized_name(path, target, output, count)
  name = "#{File.basename(path, '.*')}_#{target_label(target)}#{File.extname(path)}"
  if output && (count > 1 || output.end_with?('/') || File.directory?(output))
    File.join(output, name)
  elsif output
    output
  else
    File.join(File.dirname(path), name)
  end
end

# Gain in dB to reach +target+, with "!" when the true peak would pass the
# target's ceiling.
def gain_cell(r, target)
  gain = r.gain_to(target.lufs)
  return 'n/a' if gain.nil?
  over = target.true_peak && r.true_peak && r.true_peak + gain > target.true_peak
  format('%+.1f%s', gain, over ? '!' : '')
end

COLUMNS = ['Integrated LUFS', 'Short-term max', 'Momentary max', 'LRA LU', 'True peak dBTP', 'Seconds'].freeze

MB::Sound.script(
  args: 0..,
  json: [false, 'Print JSON instead of a table'],
  series: [false, 'With --json, include the momentary and short-term series (every 100 ms)'],
  markdown: [false, 'Print a Markdown table'],
  target: [nil, String, '-t', 'Show the gain to reach these targets (comma-separated names or LUFS)'],
  targets: [false, 'List the loudness target presets and their sources'],
  normalize: [nil, String, '-n', 'Write copies normalized to this target (a name or LUFS, e.g. spotify or -14)'],
  output: [nil, String, '-o', 'Normalized copy name (one input) or directory'],
  force: [false, '-f', 'Overwrite existing normalized copies'],
  reduce: [false, 'When normalizing, stop the gain at the target\'s true-peak ceiling'],
  true_peak: [true, 'Measure true peak (--no-true-peak is about twice as fast)'],
  accurate: [false, 'Measure true peak with the 32-tap Kaiser filter instead of BS.1770 Annex 2\'s'],
) { |paths, p|
  if p.targets
    MB::Sound::Loudness::TARGETS.each_value do |t|
      puts "#{t.key}: #{t}"
      puts "  #{t.notes}"
      puts "  Source: #{t.source}"
    end
    aliases = MB::Sound::Loudness::TARGET_ALIASES.map { |a, k| "#{a} = #{k}" }.join(', ')
    puts "Aliases: #{aliases}"
    next
  end

  raise ArgumentError, 'Pass audio files or directories to measure' if paths.empty?

  targets = p.target ? p.target.split(',').map { |t| MB::Sound::Loudness.target(t) } : []
  normalize = p.normalize && MB::Sound::Loudness.target(p.normalize)

  files = audio_files(paths)
  raise ArgumentError, 'No audio files found' if files.empty?

  true_peak = p.true_peak && (p.accurate ? :accurate : :annex2)
  results = files.map { |f|
    $stderr.write("\r\e[KMeasuring #{f}") if $stderr.tty? && !p.json
    [f, MB::Sound.loudness(f, true_peak: true_peak)]
  }
  $stderr.write("\r\e[K") if $stderr.tty? && !p.json

  columns = COLUMNS + targets.map { |t| "Gain to #{target_label(t)}" } + ['File']
  rows = results.map { |f, r|
    [level(r.integrated), level(r.short_term_max), level(r.momentary_max), level(r.range), level(r.true_peak), format('%.1f', r.duration)] +
      targets.map { |t| gain_cell(r, t) } + [f]
  }

  if p.json
    out = results.map { |f, r|
      h = { file: f }.merge(r.to_h(series: p.series))
      h[:gain_to] = targets.to_h { |t| [target_label(t), r.gain_to(t.lufs)&.round(2)] } unless targets.empty?
      h
    }
    puts JSON.pretty_generate(out.length == 1 ? out[0] : out)
  elsif p.markdown
    puts "| #{columns.join(' | ')} |"
    puts "|#{columns.map { |c| c == 'File' ? ' --- ' : ' ---: ' }.join('|')}|"
    rows.each { |r| puts "| #{r.join(' | ')} |" }
  else
    widths = columns.each_index.map { |i| ([columns[i]] + rows.map { |r| r[i] }).map(&:length).max }
    fmt = ->(cells) { cells.each_with_index.map { |c, i| i == cells.length - 1 ? c : c.rjust(widths[i]) }.join('  ') }
    puts $stdout.tty? ? "\e[1m#{fmt.(columns)}\e[0m" : fmt.(columns)
    rows.each { |r| puts fmt.(r) }
  end

  if normalize
    raise ArgumentError, '--output names one file; use a directory (ending in /) for several inputs' if p.output && files.length > 1 && !p.output.end_with?('/') && !File.directory?(p.output.to_s)

    results.each do |f, r|
      out = normalized_name(f, normalize, p.output, files.length)
      if File.exist?(out) && !p.force
        warn "#{out} exists; use -f to overwrite"
        next
      end
      FileUtils.mkdir_p(File.dirname(out))

      info = MB::Sound::Loudness.normalize_file(f, normalize, output: out, peak: p.reduce ? :reduce : :warn, true_peak: true_peak || :annex2)
      next if info[:gain].nil?

      peak = info[:true_peak] ? format(', true peak %.1f dBTP', info[:true_peak]) : ''
      $stderr.puts format('%s: %+.1f dB -> %.1f LUFS%s (%s)', out, info[:gain], info[:lufs], peak, normalize)
    end
  end
}
