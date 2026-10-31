# The mb-sound tutorial (design for a later phase)

<!-- summary -->
A design, not yet built, for a full vimtutor-style tutorial in the live console: a `tutorial` command whose chapters are lessons on the existing `Help.lesson` framework (help.md), one small A-minor piece grown from a single tone to a form with knobs and a recording, and checks that listen (`playing?`, `level_of`, knob values, landed changes) after every line typed.  Part 1 (sound basics) is about 30 minutes, the whole 2-3 hours.
<!-- /summary -->

## Quick reference

- A design, not built: a `tutorial` command whose chapters are `Help.lesson` lessons (help.md) around one A-minor piece, with checks that listen after every line.
- Read Shape and Chapters below first; Open questions lists what the maintainer still decides.

Design only (help-1, 2026-10-13); nothing here is built yet beyond the lesson framework in `help.md`.  The maintainer: "Start light but then a full vimtutor-like tutorial is warranted."

## What vimtutor gets right, and what carries over

- You learn by doing in the real tool, not by reading about it: every chapter happens in the live console (`bin/sound.rb`), with your own players, knobs, and scenes left playing at the end.
- Short numbered lessons in one sitting (~30 min for vimtutor's core), each with a summary at the end, and a clear "you can stop here" point.
- The text is the exercise: vimtutor's file is edited in place.  Here the lesson checks the Session after every line you type (the existing `after_eval` hook), so typing the code, or anything else that does the job, moves on.
- No dead ends: `lesson.run` types a step, `lesson.back`, `lesson.hint`; progress is saved, so `tutorial` resumes.

What differs: sound needs a level check first (the first chapter runs `help.level`), and checks can listen (peak/loudness of a player, a knob's value, a journal entry), not just compare text.

## Shape

- Command: `tutorial` (free: not an MB::Sound method or a Pry command, checked 2026-10-13) starts or resumes; `tutorial 4` jumps to a chapter; `tutorial.map` shows chapters with done marks.  Chapters are lessons (the same `Help.lesson` framework) grouped in parts; each ends with a summary page listing what it taught as sheet lines.
- One set built across the whole tutorial: a small piece (A minor, 120 BPM) that grows from one tone to a form with knobs and a recording, so the last chapter plays something worth saving (`take.save`).  Each chapter starts from a known state (a `setup` block that builds what earlier chapters made, so jumping in works).
- Checks that listen: new check helpers `playing?(:name)`, `level_of(:name)` (short_term LUFS from a tap), `knob(:cut).value`, `landed?(:go, :drop)`; the spec runs every chapter in order and jumped-into, as the lesson spec does now.
- Each step: two or three sentences, one line to type, one check.  Optional "explore" steps (skippable with `lesson.next`) for things like `help node` or `plot`.
- Timing: part 1 about 30 minutes, the whole thing 2-3 hours in sittings.

## Chapters

Part 1: Sound (the core, ~30 min)
1. Hello, sound: the level check, `play 220.hz` and Ctrl-C, `bg :a, 220.hz.triangle.at(-20.db)`, `stop :a`.
2. Shapes and pitches: `saw`/`square`/`triangle`, notes (`A3.hz`), intervals, `.at`, `until`.
3. Envelopes: one-shots, `adsr`, curves; why sounds end.
4. Filters: `lp4`, `filter(:lowpass)`, sweeping with `tween`; resonance.
5. Chaining and mixing: `+`, `*`, `stereo`, `pan`, the master gain and headroom.

Part 2: Time (~30 min)
6. Clips: `seq(...).n8.loop`, `clip.tone`, `clip.amp_env`, rests and ties.
7. Tempo and the timeline: `bpm`, `bar(n)`, `1.n8.dotted`, tempo-locked LFOs.
8. Scheduling: `at_bar`, `after`, `every`; launch points (`on:`, `in:`, `at:`).
9. Drums: `tr808` with `grid`, `euclid`; `swap`.

Part 3: A set (~40 min; today's `:set`, `:flow` lessons grow into these)
10. Tracks and scenes: `track`, `scene`, `go`, `quant`.
11. Undo and the journal: `undo`, `redo!`, `changes`, `now`.
12. Song forms: `flow`, labels, `goto`, `pick`, steering with `loop!`/`onward`/`finish`.
13. Ring-outs, mutes, and solos: `stop ring:`, `mute on: :bar`, mute groups.

Part 4: Performing (~30 min; today's `:knobs`, `:record`)
14. Knobs: `knob`, `knob(:x)` in graphs, `turn over:`, `snap`/`recall`, `xfade`.
15. MIDI: `midi`, `synth`, `learn`, transforms (`arp`, `echo`) (needs a keyboard; a stand-in clip otherwise).
16. Effects and the master chain: delay, reverb, `duck`, `master { |mix| mix.limit }`.
17. Recording: `arm`, `rec`, `capture`, `rec_audio`, `take.save`.

Part 5: Keeping and looking (~20 min)
18. Saving: `ruby node`, `save`, `preset`, set documents.
19. Looking: `plot`, `spectrum`, `vis`, `help node`, `loudness`.
20. Where next: `help`, topics, design notes, the demo songs in `bin/songs/`.

## Open questions for that phase

1. One continuous piece vs. independent chapters (the plan above: continuous, with setup blocks for jumping in).
2. Should checks that listen (levels, pitch) be strict, or only confirm something plays?
3. A menu (arrow keys, io/console) for `tutorial.map`, or plain text like `lesson`?
4. Chapter 15 without a keyboard: a stand-in clip played as live MIDI, or skip?
