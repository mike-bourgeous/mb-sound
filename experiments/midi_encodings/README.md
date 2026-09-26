# Can an LLM read MIDI in its head?  Six encodings compared

An experiment from a brainstorming session about representing MIDI for live
performance and collaborative iteration with LLM sessions (2026-09-26).  The
question: if a language model is handed a MIDI file as text, which text
encodings can it actually read and edit without running code?

Before the experiment, Claude predicted that raw-byte encodings (hex, Braille,
emoji, base64) would be poor to terrible, with base64 worst and editing hex
"risky".  The prediction was mostly wrong.

## Setup

- **File:** `Synth Demo 1.mid` by Mike Bourgeous (`truth/demo.mid`), written
  for a synth built on an earlier version of mb-sound.  4411 bytes, SMF format
  1, 960 ticks per quarter note, 90 bpm, 4 tracks (tempo, Pads, Bass,
  Saxophone), 154 notes and ~900 controller events.  It was played in live
  (unquantized), uses running status, and has a nonstandard 2-byte time
  signature event.
- **Encodings** (one Markdown page each, with the full contents):
  - [00 annotated hex](00-annotated-hex.md): reference decoding of the first
    bytes (not given to any decoder)
  - [01 hex dump](01-hex.md): offsets + 16 hex bytes per line
  - [02 Braille](02-braille.md): byte `b` -> U+2800+b
  - [03 emoji](03-emoji.md): byte `b` -> U+1F300+b (🌀 = 0x00, 🍍 = 0x4D)
  - [04 base64](04-base64.md)
  - [05 event CSV](05-event-csv.md): midicsv-style, lossless
  - [06 note list](06-note-list.md): beats as exact rationals, pitch names;
    drops controllers and pitch bends
- **Decoders:** six fresh Claude Opus 5.5 subagents, one per encoding, run in
  parallel.  Each could only Read its own input file and Write its outputs:
  no code, no other files, no answer key.  Prompt: [prompt.md](prompt.md).
- **Tasks:**
  1. List the first 12 Bass notes as start tick, pitch, velocity, duration
     (48 fields).  This requires summing variable-length delta times from the
     start of the track, including controller events before the first note,
     and pairing note-ons with note-offs.
  2. Count the Saxophone notes and give the lowest and highest pitch.
  3. Edit: transpose every Bass note up 2 semitones and write out the entire
     file in the same encoding.  Scored byte-for-byte (or line-for-line)
     against the expected file: 108 pitch bytes must change and nothing else.
- **Scoring:** `truth/score.rb` (raw results in [results.txt](results.txt)).

## Results

| Encoding | Size (chars) | Task 1: notes / fields | Task 2 | Task 3 edit | Time | Tokens |
|---|---:|---|---|---|---:|---:|
| Hex dump | 15,441 | 12/12, 48/48 | 3/3 | exact (108/108, 0 stray) | 4.8 min | 86k |
| Braille | 4,480 | 8/12, 44/48 | 3/3 | exact | 8.6 min | 118k |
| Emoji | 4,549 | 12/12, 48/48 | 3/3 | exact | 7.5 min | 109k |
| Base64 | 5,983 | 0/12, 36/48 | 3/3 | exact | 6.8 min | 92k |
| Event CSV | 38,183 | 12/12, 48/48 | 3/3 | exact (1,248 lines) | ~5 min* | 96k* |
| Note list | 4,473 | 12/12, 48/48 | 3/3 | exact (54/54 lines) | ~3 min* | 54k* |

\* The CSV and note list decoders were first blocked from writing files by
the session's worktree guard and were resumed with new output paths, so their
time and token totals include a retry and are approximate.  Token counts are
the subagent totals reported by the harness, not the size of the encoding.

**Every decoder produced a byte-exact edit.**  All the errors were in Task 1,
and all were delta-time mistakes that shifted every later note:

- **Base64:** every start tick was 13 early.  The Bass track has one
  controller event at tick 13 before its first note (delta 15355).  The
  decoder read the note's own delta correctly but dropped the earlier 13.
  Pitches, velocities, and durations were all correct.  (The emoji decoder
  noticed the same trap and called it out in its notes.)
- **Braille:** notes 9-12 were 64 ticks early.  The delta before note 9 is
  `81 78` (248 ticks).  Reading `0x78` ⡸ as `0x38` ⠸ gives exactly 64 less:
  the two characters differ only in dot 7, the extra bottom-row dot that
  encodes bit 6.  A perceptual slip specific to this encoding.
- The Braille decoder was also the only one to notice the malformed time
  signature event on its own, by checking that event sizes added up.

## Takeaways

- **The raw-byte encodings are not the disaster I predicted.** With a clear
  byte mapping, the model decoded SMF structure (chunks, VLQ deltas, running
  status) and produced a byte-exact 108-byte edit in every encoding, even
  base64, where it re-encoded only the affected 4-character groups.
- **But they cost 1.5-2x the tokens and 2-3x the time of the note list, and
  the errors are silent.**  An off-by-13 or off-by-64 delta shifts everything
  after it, and nothing inside the data flags it.  Semantic text formats had
  no such failure mode here: the CSV and note list make every time absolute.
- **Braille and emoji are denser in characters but not cheaper to process.**
  They took the longest of all six.
- **For LLM collaboration, semantic text still wins:** the note list was the
  cheapest and fastest, and it is the format closest to what a human would
  want to review.  Raw-byte encodings are workable for inspection and
  debugging, not for creative iteration.

## Caveats

- One file, one run per encoding, one model.  Differences of a single error
  are anecdotes, not rates.
- Tasks 1 and 2 overlap, and Task 3 changes no lengths.  The hard edits
  (inserting or deleting a note, which changes VLQ lengths and chunk length
  fields) were not tested and would likely separate the encodings much more.
- The decoders knew they were being scored and were told to be careful.
- A decoder "cheating" with code was prevented only by instructions; each
  reported using only Read and Write.

## Possible follow-ups

- Insertion/deletion edits (length changes), quantization or humanization
  edits, and a larger file that doesn't fit comfortably in context.
- Several runs per encoding to get error rates.
- The same tasks in the mb-sound `seq`/`grid` DSL once a MIDI importer exists.

## Reproducing

```bash
cd experiments/midi_encodings
ruby truth/make.rb                       # inputs in runs/*/demo.*, answer key
ruby truth/make.rb truth/expected_bass_up2.mid truth/expected   # expected edits
# run one decoder per encoding with prompt.md (fill in the paths)
ruby truth/score.rb                      # score runs/*/answers.txt and outputs
ruby make_md.rb                          # regenerate the Markdown pages
```
