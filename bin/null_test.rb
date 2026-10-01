#!/usr/bin/env ruby
# Null tests for refactors that shouldn't change the sound: renders a fixed
# set of cases (songs, synth scripts on a MIDI file, effects on a test sound,
# and bin/tone_gallery.rb), then compares new renders to reference renders
# by the residual left after subtracting them.
#
# Scripts run with RANDOM_SEED=1 so random parts repeat.  References
# aren't stored in git: `record --ref COMMIT` renders them from
# that commit in a temporary worktree.  Each case is a command line, so a
# script may be rewritten for a new API as long as its options keep working.
#
# The comparison reports the raw residual and the residual after matching
# the overall gain (so intended level changes don't fail), both in dB
# relative to the reference's RMS, and the gain-matched residual in dBFS.
# A case fails if its length differs, or if the gain-matched residual is
# above --limit (default -80 dB) and also above --floor (default -120 dBFS,
# near 24-bit FLAC quantization: very quiet renders can't null further).
#
# Usage:
#     $0 record [--ref COMMIT] DIR       # render references into DIR
#     $0 compare REF_DIR [NEW_DIR]       # render this tree and compare
#     $0 --list                          # case names
#
# Example:
#     $0 record --ref master-ai tmp/null_refs
#     $0 compare tmp/null_refs

require 'bundler/setup'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'mb-sound'

ROOT = File.expand_path('..', __dir__)
MIDI_FILE = 'spec/test_data/c_major.mid'
ARP = 'spec/test_data/arp_a7.flac'

# Case name => command line in the tree's root; %{out} is a file path, or a
# directory for cases ending in '/'
CASES = {
  'gallery/' => 'bin/tone_gallery.rb %{out}',

  'song_stereo_drone' => 'bin/songs/stereo_drone.rb -q -f -b 4 %{out}',
  'song_sequence_demo' => 'bin/songs/sequence_demo.rb -q -f -b 2 %{out}',
  'song_tempo_song' => 'bin/songs/tempo_song.rb -q -f -b 4 %{out}',
  'song_stereo_song' => 'bin/songs/stereo_song.rb -q -f -b 2 %{out}',
  'song_scheduled_song' => 'bin/songs/scheduled_song.rb -q -f -b 2 %{out}',
  'song_node_graph_grit' => 'bin/songs/node_graph_grit.rb -q -f -b 1 %{out}',

  'synth_sinewave' => "bin/synths/sinewave.rb -q -f #{MIDI_FILE} %{out}",
  'synth_fm_bass' => "bin/synths/fm_bass.rb -q -f #{MIDI_FILE} %{out}",
  'synth_fm_bell' => "bin/synths/fm_bell.rb -q -f #{MIDI_FILE} %{out}",
  'synth_fm_bellpad' => "bin/synths/fm_bellpad.rb -q -f #{MIDI_FILE} %{out}",
  'synth_fm_synth' => "bin/synths/fm_synth.rb -q -f --no-table #{MIDI_FILE} %{out}",
  'synth_fm_drumbass' => "bin/synths/fm_drumbass.rb -q -f #{MIDI_FILE} %{out}",
  'synth_ep2_syn' => "bin/synths/ep2_syn.rb -q -f #{MIDI_FILE} %{out}",
  'synth_simple_syn' => "bin/synths/simple_syn.rb -q -f #{MIDI_FILE} %{out}",
  'synth_filter_ping' => "bin/synths/filter_ping.rb -q -f #{MIDI_FILE} %{out}",
  'synth_stereo_graph' => "bin/synths/stereo_graph_synth_example.rb -q -f #{MIDI_FILE} %{out}",
  'synth_wavetable_bass' => "bin/synths/wavetable_bass.rb -q -f #{MIDI_FILE} %{out}",

  'fx_flanger' => "bin/effects/flanger.rb -q -f --oversample 1 #{ARP} %{out}",
  'fx_ping_pong_delay' => "bin/effects/ping_pong_delay.rb -q -f #{ARP} %{out}",
  'fx_tape_delay' => "bin/effects/tape_delay.rb -q -f --oversample 1 #{ARP} %{out}",
  'fx_reverse_delay' => "bin/effects/reverse_delay.rb -q -f --oversample 1 #{ARP} %{out}",
}.freeze

# Renders every case (or those whose names contain one of +only+) from the
# tree at +root+ into +dir+.
def render_all(root, dir, only)
  FileUtils.mkdir_p(dir)
  CASES.each do |name, cmd|
    next if only && only.none? { |o| name.include?(o) }

    out = File.join(File.expand_path(dir), name.delete_suffix('/'))
    out += '.flac' unless name.end_with?('/')
    FileUtils.rm_rf(out)
    t = MB::U.clock_now
    text, status = Open3.capture2e({ 'RANDOM_SEED' => '1' }, format(cmd, out: out.shellescape), chdir: root)
    unless status.success?
      warn text
      abort "Case #{name} failed in #{root}"
    end
    puts format('  %-24s %5.1f s', name, MB::U.clock_now - t)
  end
end

# Returns the audio files for a case output (a file or a directory).
def case_files(dir, name)
  return Dir[File.join(dir, name, '*.flac')].sort if name.end_with?('/')

  [File.join(dir, "#{name}.flac")]
end

def db(ratio)
  ratio > 0 ? 20 * Math.log10(ratio) : -Float::INFINITY
end

# Compares two renders; returns a Hash of measurements.
def compare_file(ref_path, new_path)
  ref = MB::Sound.read(ref_path).map { |c| c.cast_to(Numo::DFloat) }
  new = MB::Sound.read(new_path).map { |c| c.cast_to(Numo::DFloat) }
  return { error: "channels #{ref.length} vs #{new.length}" } if ref.length != new.length

  frames = [ref[0].length, new[0].length].min
  ref = ref.map { |c| c[0...frames] }
  new = new.map { |c| c[0...frames] }

  ref_energy = ref.sum { |c| (c**2).sum }
  new_energy = new.sum { |c| (c**2).sum }
  cross = ref.zip(new).sum { |r, n| (r * n).sum }
  gain = new_energy > 0 ? cross / new_energy : 1.0

  raw = ref.zip(new).sum { |r, n| ((r - n)**2).sum }
  aligned = ref.zip(new).sum { |r, n| ((r - n * gain)**2).sum }
  samples = ref.sum(&:length)

  {
    frames: frames,
    length_diff: MB::Sound.read(new_path)[0].length - MB::Sound.read(ref_path)[0].length,
    gain_db: db(gain.abs),
    raw_db: ref_energy > 0 ? db(Math.sqrt(raw / ref_energy)) : db(Math.sqrt(raw)),
    aligned_db: ref_energy > 0 ? db(Math.sqrt(aligned / ref_energy)) : db(Math.sqrt(aligned)),
    aligned_dbfs: db(Math.sqrt(aligned / samples)),
  }
end

MB::Sound.script(
  args: 0..3,
  ref: [nil, String, 'Commit to render references from (record)'],
  only: [nil, String, 'Comma-separated substrings; only matching cases'],
  limit: [-80.0, Float, 'Maximum gain-matched residual in dB relative to the reference'],
  floor: [-120.0, Float, 'Gain-matched residuals below this dBFS always pass'],
  list: [false, '-l', 'List case names and exit'],
) { |(command, dir1, dir2), p|
  if p.list
    puts CASES.keys
    next
  end
  only = p.only&.split(',')

  case command
  when 'record'
    abort 'Give a directory to record into' unless dir1
    dir1 = File.expand_path(dir1)
    if p.ref
      Dir.mktmpdir('null-test-ref-') do |tmp|
        tree = File.join(tmp, 'tree')
        system('git', '-C', ROOT, 'worktree', 'add', '-q', '--detach', tree, p.ref, exception: true)
        begin
          puts "Compiling #{p.ref} in #{tree}"
          system('bundle', 'exec', 'rake', 'compile', chdir: tree, out: File::NULL, exception: true)
          render_all(tree, dir1, only)
        ensure
          system('git', '-C', ROOT, 'worktree', 'remove', '--force', tree)
        end
      end
    else
      render_all(ROOT, dir1, only)
    end
    puts "References in #{dir1}"

  when 'compare'
    abort 'Give the reference directory' unless dir1
    new_dir = dir2 || Dir.mktmpdir('null-test-new-')
    render_all(ROOT, new_dir, only)

    failures = 0
    puts format('%-40s %8s %6s %9s %9s %11s %9s', 'case', 'frames', 'len±', 'gain dB', 'raw dB', 'matched dB', 'dBFS')
    CASES.each_key do |name|
      next if only && only.none? { |o| name.include?(o) }

      case_files(dir1, name).each do |ref_path|
        label = name.end_with?('/') ? "#{name}#{File.basename(ref_path, '.flac')}" : name
        new_path = File.join(new_dir, name.end_with?('/') ? name : '', File.basename(ref_path))
        unless File.exist?(new_path)
          puts format('%-40s missing', label)
          failures += 1
          next
        end

        r = compare_file(ref_path, new_path)
        if r[:error]
          puts format('%-40s %s', label, r[:error])
          failures += 1
          next
        end

        ok = (r[:aligned_db] <= p.limit || r[:aligned_dbfs] <= p.floor) && r[:length_diff] == 0
        failures += 1 unless ok
        puts format('%-40s %8d %6d %9.2f %9.1f %11.1f %9.1f %s', label, r[:frames], r[:length_diff], r[:gain_db], r[:raw_db], r[:aligned_db], r[:aligned_dbfs], ok ? '' : 'FAIL')
      end
    end

    puts failures == 0 ? "All cases null below #{p.limit} dB" : "#{failures} case(s) differ"
    exit(failures == 0 ? 0 : 1)

  else
    abort "Unknown command #{command.inspect}; use record or compare (see --help)"
  end
}
