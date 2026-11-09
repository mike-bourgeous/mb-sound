# Importers: finding foreign files (`MB::Sound::MediaIndex`)

<!-- summary -->
`MB::Sound::MediaIndex.for(root)` (`lib/mb/sound/media_index.rb`) is the one way importers find the local copy of a file a foreign project names by another machine's path (Windows `D:\...` or POSIX): it walks a media root once, indexes files by name (lower case, NFC), and `#resolve(path)` returns a `Match` (path, `:found`/`:ambiguous`/`:missing`, matching trailing folders, candidates best first, ties), choosing among same-named files by the most matching trailing folders.
`.for` caches an index per root and options while its folders' mtimes hold.  SFZ samples named in another letter case are found through it (every folder must match).  The .acd converter's own lookup (research branch) is to switch to it.
<!-- /summary -->

## Quick reference

- `idx = MB::Sound::MediaIndex.for(root, hidden: false, extensions: nil)`; `idx.resolve('D:\\Loops\\Drums\\Kick.wav', warn: true)` (a `Match`: `path`, `status`, `folders`, `candidates`, `tied`, `message`), `idx[path]`/`idx.find(path)`, `idx.files(name)`, `idx.ambiguous`, `idx.fresh?`, `MediaIndex.clear_cache`.
- SFZ: `Sampler::SFZ.local_sample(base, file)` (`CASE_FOLDERS_UP`), used by `MB::Sound.sfz` for a sample path that doesn't exist.
- Specs: `spec/lib/mb/sound/media_index_spec.rb`, the SFZ letter-case example in `spec/lib/mb/sound/sampler_spec.rb`.

Branch `importer-media-1`, 2026-11-09.  The brief: a media index for importers in mb-sound proper.  The .acd converter (research branch `research-acd-model`, `research/acd-format/acd/map/media.rb`) had its own: walk a media root once, index files by lowercased name, resolve a project's saved Windows path by name, then by the most matching trailing folders, warning when several same-named files compete (2026-11-09: a pack loop and a processed copy of it for one project had the same name, and name-only lookup picked the wrong one).

## What the library had (survey, 2026-11-09)

Nothing resolved foreign paths.  `GraphIO::FileGuard` confines a graph document's file names to its directory (a different job: it never searches); `Playable#string` suggests names in a missing file's folder (`GraphIO.suggest`); `Library` walks its shelves for documents; `LoopInfo` globs a loop folder.  The importers: tracker modules (MOD, 669, S3M, XM, IT) embed their samples, SoundFonts embed theirs, and MIDI files are read from the path given, so none of them meets another machine's paths.  SFZ files name samples relative to themselves, and those made on case-insensitive disks often differ from the disk's letter case: the one library consumer today.

## Resolution rules

- Names compare in `MediaIndex.key` form: Unicode NFC (macOS may hand out NFD names), lower case, invalid bytes scrubbed.  A saved path splits on both separators; empty and `.` parts are dropped, so `C:`, `\\?\` prefixes, and relative paths need no special cases.
- One file of the name: `:found`.  Several: `:ambiguous`, the best by trailing parts matching from the name up over the full local path (so the media root's own folder names count, as in the converter); ties go to the first in full-path string order (the converter's `index` order).  `folders` is the matched count minus the name; `tied` counts candidates at the best score.  `warn: true` prints `Match#message` once per saved path and choice per index.
- Dot files and folders are left out unless `hidden: true` (the converter's audio lookup left them out, its .mid lookup kept them).  `extensions:` limits file types.  Links to files are listed; linked folders are not followed (like `Dir.glob`'s `**`; no loops).
- Cache: `.for` keys on the expanded root, `hidden`, and `extensions`; an index records every folder's mtime and is reused while all are unchanged (`#fresh?`: adding, removing, or renaming a file changes its folder's mtime; contents don't matter to a name index), at most `CACHE_SIZE` (8) roots, least recently used out.
- Measured (Linux runner, warm disk cache, /usr: 37,655 files in 5,089 folders): walk 0.28 s (a `Dir.glob` + `File.file?` pass, the converter's, 0.20 s; the walk also stats folders for the cache), `#fresh?` 14 ms, 1000 resolves 12 ms.  Cold disk cache: 1.1 s.

## SFZ letter case

`SFZ.local_sample` runs only when a sample path doesn't exist: it indexes the folder holding both the SFZ file and the sample (climbing at most `CASE_FOLDERS_UP` = 2 folders above the SFZ's for `../` paths) and takes the match only when every folder below that root matched, so a same-named file in another folder is never substituted (the read then fails as before).  In a graph document the found name is registered as a document name, so FileGuard checks it like any other.

## The .acd converter's switch (after the merge)

`Acd::Media` keeps two lookups that differ only in dot files and in a corner of ordering: `index`/`local` (audio takes, sfz files; dot paths out, full-path sort) and `tail_index`/`resolve` (external .mid takes; dot paths in, `Dir.glob` order, which sorts per folder level: `a-b/x` vs `a/x` order differently than a full-path sort).  The switch: `Context#media_index` becomes `MediaIndex.for(media)`, `#tail_index` `MediaIndex.for(media, hidden: true)`; `Media.local(idx, path, warnings:)` becomes `m = idx.resolve(path)` with the converter's Warnings fed `m.message` when `m.ambiguous?` (its warning text changes); `Media.resolve` becomes `[m.status, m.path]`.  Expected output change (it also compares names in NFC): none for files without dot folders or `a-b`/`a/` sibling ties; the converter's golden specs say.
