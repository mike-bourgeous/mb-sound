#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures the loudness of audio files per ITU-R BS.1770-4 / EBU R 128:
# integrated loudness (LUFS), short-term (3 s) and momentary (400 ms)
# maxima, loudness range (LRA, EBU Tech 3342), and true peak (dBTP).
# Optionally writes copies normalized to a target integrated loudness.
#
# Usage: $0 [options] FILE_OR_DIR [...]
#
# Directories are searched recursively for audio files.  Files are read at
# their own sample rate.  Channel weights follow the channel count
# (ffmpeg/SMPTE order: L R C LFE Ls Rs; LFE excluded, surrounds +1.5 dB);
# mono files read 3 LU below the same signal on both stereo channels, as
# the standard says.
#
# Examples:
#     $0 tmp/listening                       # table of every file
#     $0 --json song.flac                    # JSON (add --series for M/S curves)
#     $0 --markdown tmp/listening/*/         # Markdown table (for notes)
#     $0 --normalize -14 song.flac           # writes song_-14lufs.flac
#     $0 -n -16 -o loud.flac quiet.flac      # normalized copy with a name
#     $0 -n -23 -o out_dir/ a.flac b.flac    # copies into a directory
#
# Normalizing only applies gain (no limiter): a warning is printed when the
# copy's true peak would be above -1 dBTP, and integer formats (FLAC, most
# WAV) clip above 0 dBFS.  Same-name files are kept unless -f is given.
#
# In the console (bin/sound.rb): loudness('song.flac').lufs, or a live
# meter on anything playing: m = song.loudness_meter; bg m; m.to_s

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

# The default name of a normalized copy, e.g. song_-14lufs.flac.
def normalized_name(path, target, output, count)
  name = "#{File.basename(path, '.*')}_#{format('%g', target)}lufs#{File.extname(path)}"
  if output && (count > 1 || output.end_with?('/') || File.directory?(output))
    File.join(output, name)
  elsif output
    output
  else
    File.join(File.dirname(path), name)
  end
end

COLUMNS = ['Integrated LUFS', 'Short-term max', 'Momentary max', 'LRA LU', 'True peak dBTP', 'Seconds', 'File'].freeze

def row(path, r)
  [level(r.integrated), level(r.short_term_max), level(r.momentary_max), level(r.range), level(r.true_peak), format('%.1f', r.duration), path]
end

MB::Sound.script(
  args: 1..,
  json: [false, 'Print JSON instead of a table'],
  series: [false, 'With --json, include the momentary and short-term series (every 100 ms)'],
  markdown: [false, 'Print a Markdown table'],
  normalize: [nil, Float, '-n', 'Write copies with this integrated loudness in LUFS (e.g. -14)'],
  output: [nil, String, '-o', 'Normalized copy name (one input) or directory'],
  force: [false, '-f', 'Overwrite existing normalized copies'],
  true_peak: [true, 'Measure true peak (--no-true-peak is about twice as fast)'],
) { |paths, p|
  files = audio_files(paths)
  raise ArgumentError, 'No audio files found' if files.empty?

  results = files.map { |f|
    $stderr.write("\r\e[KMeasuring #{f}") if $stderr.tty? && !p.json
    [f, MB::Sound.loudness(f, true_peak: p.true_peak)]
  }
  $stderr.write("\r\e[K") if $stderr.tty? && !p.json

  if p.json
    out = results.map { |f, r| { file: f }.merge(r.to_h(series: p.series)) }
    puts JSON.pretty_generate(out.length == 1 ? out[0] : out)
  elsif p.markdown
    puts "| #{COLUMNS.join(' | ')} |"
    puts "|#{COLUMNS.map { |c| c == 'File' ? ' --- ' : ' ---: ' }.join('|')}|"
    results.each { |f, r| puts "| #{row(f, r).join(' | ')} |" }
  else
    rows = results.map { |f, r| row(f, r) }
    widths = COLUMNS.each_index.map { |i| ([COLUMNS[i]] + rows.map { |r| r[i] }).map(&:length).max }
    fmt = ->(cells) { cells.each_with_index.map { |c, i| i == cells.length - 1 ? c : c.rjust(widths[i]) }.join('  ') }
    puts $stdout.tty? ? "\e[1m#{fmt.(COLUMNS)}\e[0m" : fmt.(COLUMNS)
    rows.each { |r| puts fmt.(r) }
  end

  if p.normalize
    raise ArgumentError, '--output names one file; use a directory (ending in /) for several inputs' if p.output && files.length > 1 && !p.output.end_with?('/') && !File.directory?(p.output.to_s)

    results.each do |f, r|
      gain = r.gain_to(p.normalize)
      if gain.nil?
        warn "#{f}: silent, not normalized"
        next
      end

      out = normalized_name(f, p.normalize, p.output, files.length)
      if File.exist?(out) && !p.force
        warn "#{out} exists; use -f to overwrite"
        next
      end
      FileUtils.mkdir_p(File.dirname(out))

      info = MB::Sound::FFMPEGInput.new(f)
      rate = info.sample_rate
      info.close
      data = MB::Sound.read(f, sample_rate: nil).map { |c| c * 10.0 ** (gain / 20.0) }
      MB::Sound.write(out, data, sample_rate: rate, overwrite: true)

      peak = r.true_peak && r.true_peak + gain
      $stderr.puts "#{out}: #{format('%+.1f', gain)} dB -> #{format('%.1f', p.normalize)} LUFS#{peak ? ", true peak #{format('%.1f', peak)} dBTP" : ''}"
      warn "  warning: true peak above -1 dBTP#{peak > 0 ? ' (clips in integer formats)' : ''}; no limiter is applied" if peak && peak > -1
    end
  end
}
