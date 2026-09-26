# Decoder prompt

Each decoder subagent got this prompt, with `INPUT`, `OUTPUT`, `ANSWERS`, and
the encoding description filled in (see the per-encoding descriptions in
`make_md.rb`; the Braille prompt also listed the dot-to-bit mapping, and the
note list prompt gave the tick conversion and C4 = 60).

```text
You are a participant in a controlled experiment measuring how well a language
model can read and edit MIDI data *in its head* when given different text
encodings. Your accuracy will be scored automatically, so honesty matters more
than looking good.

STRICT RULES:
- Use ONLY the Read tool (to read your input file) and the Write tool (to write
  your output files). Do NOT use Bash, do NOT write or run any code/scripts, do
  NOT use any other tool. All decoding must be done by your own reasoning.
- Read ONLY this file: INPUT. Do not look at any other file or directory (other
  files contain the answers; peeking invalidates the experiment). Do not search
  for the original .mid file anywhere.
- If you give up on something, say so rather than guessing silently. Guessing
  is allowed but label guesses.

INPUT: <encoding description>

The MIDI file is format 1 with several tracks. Track 3 (counting the tempo
track as track 1) is named "Bass"; track 4 is "Saxophone".

TASKS:
1. List the first 12 notes of the "Bass" track in time order, one per line, as:
   start_tick pitch velocity duration_ticks (start_tick = absolute tick from
   start of track; pitch = MIDI note number; velocity = note-on velocity;
   duration = note-off tick minus note-on tick).
2. For the "Saxophone" track: total number of notes, lowest pitch, highest
   pitch (MIDI numbers).
3. EDIT: produce a modified version of the entire file in which every note in
   the "Bass" track is transposed up 2 semitones (both note-on and matching
   note-off events), and nothing else changes. Write the complete modified
   file, in the exact same encoding/format as the input, to OUTPUT using the
   Write tool.

Write your answers for tasks 1 and 2 to ANSWERS in this format:
TASK1
<12 lines>
TASK2
notes=<n> lowest=<p> highest=<p>
NOTES
<brief honest notes: difficulties, confidence per task (0-100%), anything you
skipped or guessed>

Then reply with a short summary including your confidence per task.
```
