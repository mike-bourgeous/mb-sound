#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Renders library presets as a Listening Bench set, loudness-matched.
#
# Usage: $0 [options] WHAT [...]
#        $0 --notes NOTES_EXPORT.json SET_ID
#
# WHAT is a family (reverb, chorus, delay, struck), a kind (effect,
# instrument, kit), a head path (L.fx.reverb, L.inst.dnb, inst.dnb), a
# family and name (reverb.hall), or an entry name (dnb_reese); --find adds
# what a find query matches.  Each preset renders on standard material
# (Library::Bench, design/notes/library.md): effects on the A7 arp, the
# jungle break, and a saw pad (after a dry reference of each), instruments
# on two phrases for their role and their genre template's phrase, kits on
# two beats and a template beat.  Every render is matched to one loudness,
# the loudest every one of them reaches with its true peak at most -1 dBTP
# (--ceiling; --lufs matches to a loudness instead, turning down the
# renders that would pass the ceiling), and written into DIR/SET_ID/ with
# set.json and bench_set.py, the Listening Bench set (build_manifest.py
# execs bench_set.py; nothing is published).  DIR defaults to tmp/listening
# in the repository's main checkout ($MB_SOUND_BENCH_DIR overrides), so sets
# rendered in a worktree outlive it.  SQ-80 entries are skipped unless named
# (no SQ-80 in demos).
#
# --vs REF renders the same presets in another checkout (a worktree path,
# or a branch some worktree has checked out) as "before" variants, from
# the same dry inputs, with this checkout's Bench code, matched with this
# checkout's renders to one loudness.
#
# --notes reads an export of the Bench page's `notes` collection (a JSON
# object of note documents, or an array of them) and prints, per preset,
# the verdict and notes for each material, then a fix list and the presets
# that sound good.
#
# Examples:
#     $0 reverb -d /app/tmp/listening          # every reverb preset
#     $0 L.inst.dnb --materials template       # the dnb patches on their song phrases
#     $0 --find 'dark bass' --mp3              # smaller files
#     $0 delay --vs master-ai                  # before/after, a master-ai worktree
#     $0 reverb --list                         # what would render
#     $0 --notes notes.json presets-reverb-2026-10-30 -d /app/tmp/listening
#
# In the console (bin/sound.rb): L.fx.reverb.bench, L.fx.reverb.hall.bench,
# and play L.fx.reverb.hall.audition(:break) plays one render's graph.

require 'bundler/setup'
require 'mb-sound'

MB::Sound.script(
  args: 0..,
  find: [nil, String, '-F', 'Add the entries a find query matches (e.g. "dark bass")'],
  dir: [MB::Sound::Library::Bench.default_root, String, '-d', 'Directory the set goes in, one folder per set'],
  id: [nil, String, 'Set id (default presets-WHAT-DATE, -r2 ... when taken)'],
  title: [nil, String, 'Set title'],
  materials: [nil, String, '-m', 'Only these materials, comma-separated (arp, break, pad, bass_riff, template, ...)'],
  lufs: [nil, Float, 'Match every render to this loudness (LUFS; default: the loudest every render reaches under the ceiling)', -40.0..-3.0],
  ceiling: [MB::Sound::Library::Bench::CEILING, Float, 'Highest true peak after matching (dBTP)', -12.0..0.0],
  mp3: [false, 'Write 320 kbps MP3 instead of FLAC (smaller sets)'],
  vs: [nil, String, 'Also render in this checkout (a worktree path or a checked-out branch) as "before"'],
  dry: [true, 'Dry reference items for effect materials'],
  list: [false, '-l', 'Print what would render, without rendering'],
  notes: [nil, String, '-N', 'Read this Bench notes export (JSON) for the set id given as the argument'],
  json: [false, 'With --notes, print JSON'],
  quiet: [false, '-q', 'Print only the summary'],
) { |args, p|
  bench = MB::Sound::Library::Bench
  # (a selection, material, set, or checkout that isn't there: one line)
  user_error = lambda do |&block|
    block.call
  rescue bench::Error => e
    raise MB::Sound::ScriptRunner::InputError, e.message
  end

  if p.notes
    raise MB::Sound::ScriptRunner::InputError, 'Pass the set id (or its directory) after --notes FILE' unless args.length == 1
    notes = user_error.() { bench.read_notes(args[0], p.notes, root: p.dir) }
    puts p.json ? JSON.pretty_generate(notes.to_h) : notes
    next
  end

  raise MB::Sound::ScriptRunner::InputError, 'Pass what to bench (a family like reverb, a kind, a head path, an entry), or --find' if args.empty? && p.find.nil?

  result = user_error.() {
    bench.run(
      args, find: p.find, root: p.dir, id: p.id, title: p.title, materials: p.materials&.split(',')&.map(&:strip),
      dry: p.dry, lufs: p.lufs, ceiling: p.ceiling, format: p.mp3 ? 'mp3' : 'flac', vs: p.vs, list: p.list,
      io: p.quiet ? nil : $stdout
    )
  }
  puts result if p.list || p.quiet
}
