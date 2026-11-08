#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Measures sound files beat by beat, bar by bar, and section by section, or compares two.
#
# Usage: $0 [options] FILE [FILE_B]
#
# One file: per beat, bar, section, and song the onset timing per band
# (low/mid/high), loudness (LUFS, momentary and short-term maxima, RMS,
# sample and true peak, crest, tails after hits), octave band levels,
# centroid and tilt, stereo width and correlation, and chroma and key
# (MB::Sound::BarStats), with a broadcast loudness report as ffmpeg's
# ebur128 prints it: integrated (BS.1770-4), LRA (EBU Tech 3342), max
# true peak, max momentary and short-term, PLR, and pass/fail for EBU R
# 128 (-23 LUFS, -1 dBTP), ATSC A/85 (-24), and streaming (-14, -1 dBTP).
#
# Two files: FILE_B measured on FILE's grid and compared bar by bar: each
# band's lag of B behind A, what moved in each bar, the worst bars, and
# likely causes (a late bus or track, missing reverb, over-compression, a
# missing band, a transpose, a mono fold, a level step), as a narrative.
#
# The grid: a fresh sidecar's (renders with `bar_stats: true` write one
# on their exact grid), --bpm for a known tempo (a constant grid, bar 1's
# downbeat at --offset seconds, 0 by default), else beat tracking (also
# with --track, --bpm then a hint).  The report's Grid line says which.
# Comparing, bars whose RMS is under --silence dBFS in both files are left
# out (digital zero against a noise floor isn't a +90 dB change).
#
# Examples:
#     $0 song.flac                          # report: broadcast loudness, sections
#     $0 --bars song.flac                   # plus a table of every bar
#     $0 -b 140 --save song.flac            # writes song.flac.bar_stats.rb
#     $0 -b 140 v15.flac v13.flac           # compare: worst bars, causes
#     $0 -b 140 --check --timing 2 a.flac b.flac   # exit 1 naming failing bars
#     $0 -t ebu_r128,-16 song.flac          # other delivery targets
#
# In the console (bin/sound.rb): r = bar_stats('song.flac', bpm: 140);
# r.bars[:lufs]; c = compare_bars('a.flac', 'b.flac'); c.check!(timing: 2);
# render('song.flac', bars: 64, bar_stats: true) { song }.

require 'bundler/setup'
require 'mb-sound'

# A number for the bar table (n/a for nil, -inf for silence).
def cell(v, digits = 1)
  return 'n/a' if v.nil?
  v.finite? ? format("%.#{digits}f", v) : '-inf'
end

MB::Sound.script(
  args: 1..2,
  bpm: [nil, Float, '-b', 'Tempo (BPM): a constant grid from --offset (a hint with --track)', 20.0..400.0],
  offset: [nil, Float, '-o', 'Seconds to bar 1\'s downbeat (with --bpm; default 0)', 0.0..3600.0],
  track: [false, 'Track the beats instead of a constant grid (--bpm as a hint)'],
  silence: [-60.0, Float, 'Comparing: bar RMS (dBFS) under which a bar is silent', -200.0..0.0],
  beats_per_bar: [4, Integer, 'Beats in a bar (constant and tracked grids)', 1..32],
  sections: [true, 'Find sections (--no-sections leaves them out)'],
  bars: [false, 'Print a table of every bar'],
  save: [false, 'Write the sidecar beside the file (FILE.bar_stats.rb)'],
  cache: [true, 'Read a fresh sidecar instead of measuring (--no-cache measures)'],
  target: [nil, String, '-t', 'Delivery targets (comma-separated names or LUFS; default ebu_r128,atsc_a85,spotify)'],
  align: [0.0, Float, 'Seconds FILE_B starts later than FILE (comparing)', -60.0..60.0],
  timing: [nil, Float, 'Timing threshold in ms (comparing; default 5)', 0.0..1000.0],
  lufs: [nil, Float, 'Loudness threshold in LU (comparing; default 1)', 0.0..60.0],
  check: [false, 'Comparing: exit 1, naming the failing bars, unless every bar is within the thresholds'],
  worst: [10, Integer, 'Bars to list when comparing', 0..1000],
) { |files, p|
  targets = p.target ? p.target.split(',').map { |t| t.match?(/\A[-+]?\d/) ? Float(t) : t.strip.to_sym } : MB::Sound::BarStats::Broadcast::TARGETS
  options = { bpm: p.bpm, offset: p.offset, beats_per_bar: p.beats_per_bar, sections: p.sections ? :auto : false, targets: targets }
  options[:grid] = :track if p.track
  files.each { |f| raise ArgumentError, "No such file: #{f}" unless File.file?(f) }

  $stderr.write("\r\e[KMeasuring #{files.first}") if $stderr.tty?
  a = MB::Sound::BarStats.analyze(files.first, **options, save: p.save, cache: p.cache)
  $stderr.write("\r\e[K") if $stderr.tty?

  if files.length == 1
    puts a
    if p.bars
      puts
      puts 'bar   start  LUFS  peak  crest  low ms  mid ms  high ms  width  key'
      a.bars.each do |r|
        puts format('%3d %7.2f %5s %5s %6s %7s %7s %8s %6s  %s', r[:bar], r[:seconds], cell(r[:lufs]), cell(r[:true_peak]), cell(r[:crest]),
                    cell(r[:onset_low]), cell(r[:onset_mid]), cell(r[:onset_high]), cell(r[:width]), r[:key] || '?')
      end
    end
    puts "\nbar statistics in #{MB::Sound::BarStats::Sidecar.path(files.first)}" if p.save
    next
  end

  thresholds = { timing: p.timing, lufs: p.lufs }.compact
  $stderr.write("\r\e[KComparing #{files.last}") if $stderr.tty?
  c = MB::Sound::BarStats.compare(a, files.last, align: p.align, thresholds: thresholds, labels: files.map { |f| File.basename(f) },
                                  silence: p.silence, **options.except(:bpm, :offset, :sections, :grid))
  $stderr.write("\r\e[K") if $stderr.tty?
  puts c.narrative
  worst = c.worst(p.worst).select { |b| b.score >= 1 }
  unless worst.empty?
    puts "\nWorst bars:"
    worst.each { |b| puts "  #{b}" }
  end
  if p.check && !c.pass?
    $stderr.puts "\n#{files.last} fails against #{files.first}: #{c.failures.group_by(&:measure).map { |m, l| "#{m} in #{MB::Sound::BarStats::Comparison.bars_text(l.map(&:bar))}" }.join('; ')}"
    exit 1
  end
}
