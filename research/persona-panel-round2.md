# Persona panel, round 2: what a repeat panel should test

Written 2026-10-13 on branch `genre-1` for the maintainer's "potentially repeat the experiment when there are more features".  Round 1: `research-persona-panel` 0c08a17d (briefs, transcript, report) and the persona branches `research-persona-edm` 323fb7e8 (Kez Volta), `-jungle` d6812824 (Nev Ashdown), `-zen` 88580e49 (Kaede Rowntree), `-looper` 7dff04a0 (Tiko Marvell); friction IDs below are from their `friction.md` files (edm `#n`, jungle/looper `Fn`, zen `n`).

## When to run it

After the panel's ranked features have landed, in their order of consensus (round 3: C exact takes first for all four; then A sampler, B buses, D per-clip clocks, E mastering presets and `ring: :all`):

- **A** sampler / audio capture (one object for bounce, slices, offsets, reverse, loop_audio, overdub) — not built yet.
- **B** buses, sends, bus sidechain (`buses-1`, in progress).
- **drums-2**: `tr909` (the `:house`/`:techno` templates wait for it) and the "second drum machine with a click layer and a real snare crack" (Kez, round 3).
- **genre templates** (`genre-1`): starting points for each persona.
- **C** exact takes: largely done since round 1 (fixes-3..7: exact take replays and endings, `lead:` landings, tr808 and lanes buffer-size invariant, `exact_lanes`); round 2 verifies rather than discovers.

## Method changes from round 1

1. **Start each persona from their template.**  `genre(:dnb)` for Kez, `:jungle` for Nev, `:ambient` for Kaede, `:funk` for Tiko; each writes a new 2-3 minute song that begins with `genre(:x).setup` or `genre(:x) { ... }` and changes what their taste demands.  Report: which template fields they kept, overrode, or fought (a direct measure of whether templates capture the genre), and what they had to add outside the template.
2. **Same personas, plus one new**: keep the four for continuity (their round-1 friction is the baseline), add a house/techno persona once `tr909` exists, so the stubs get real research and a real song.
3. **Same timing and friction format** (category, minutes, wished-for code), so round 1 and round 2 totals compare: round 1 was edm 25 entries / ~122 min, jungle 21 / ~242 min, zen 20 / ~150 min (summed from its table: 99 min API, 45 takes, 6 help), looper 28 / ~191 min.
4. **Performed takes required**, saved and replayed at 800 and 367/368 (round 1's biggest time sinks were take bugs; round 2 should spend that time on music).
5. **Listening**: renders with stems on the Listening Bench, and the maintainer's verdicts fed back to each persona for one revision before the panel talks.

## What each persona should test (from round 1's friction)

### Kez Volta (EDM / DnB)
- Bus sidechain: `duck(:drums, only: :kick)` instead of a ghost kick per ducked part (#7, #15); the template's `duck:` roles should then key from the drums bus (replace `Template#pulse_kick`).
- Bounce / resample: `reese.bounce(1.bar, root: F1)` into a sample wavetable, then formant, comb, chop (#10, H2).
- Render one section: `render(from: :drop, bars: 8)` or `--from` (#8).
- Takes from scripts: `song_script(take:)` or `--take` (#9; jungle F15, looper F1 asked the same).
- Club mastering: a loudness target that drives the limiter (`master :club`, short-term LUFS, crest factor, decoded-mp3 true peak) (#13, #19, H5); `mono_below` as one call (#14) — the dnb template's `mono_below 120` is data only today.
- Chord literals in `seq` (#6; jungle F9), `clip.halftime` (#16, H3).
- 128-frame realtime: GC pauses and scene builds (#20).

### Nev Ashdown (jungle)
- The sampler as a tracker: `rec.slices(16)`, offsets (`rec.at(7.n16)`, 9xx), slice and pitch kept separate, reverse per hit, truncating voice (F1-F5); compare with the template's chop clips, which today are key-zone Notes (`Note.new(6)` for the kick slice).
- Sampler character: 12-bit, S950 filter, cyclic timestretch (F6).
- Per-clip tempo for a record pressed at 138.75 BPM (F7, F8); a warning when a batched `bpm` is reverted.
- Per-step velocity in `seq` (F10).
- Mix reports per track and section (F16): `render(report: :tracks)`; the genre demo's `Mix#report` covers only integrated LUFS and true peak.
- `help :sampler` and a chop lesson the day A lands (round 3).

### Kaede Rowntree (ambient)
- Tails: sums that ring until all inputs end, or `ring: :all` (4); verify gongs and reverbs aren't cut.
- Live room levels: reverb `mix:` as a node or the universal wet/dry (5), and one shared room on a bus (6, B).
- Loops that keep their own clock in seconds (3, 14): the ambient template's bowl clips are whole-note loops at 60 BPM and follow the tempo; test `clock(seconds:)` / `free: true` when D lands.
- `dust`, `drift`, a modal bowl/gong node (2, 9, 10), `help :textures` (19); the template's weather (rain, river) lives in `tin_roof.rb`, so a texture library would let the template carry it.
- Quiet mastering as a named preset (`master :quiet`) next to `:club` (round 2 b).
- Preset params as knobs: graph documents' params take numbers only, so the template's `:space` and `:wear` can't be knobs of the presets; test whether params accepting nodes (or knobs) would let templates ride them.

### Tiko Marvell (looper)
- Audio looper: `loop_audio :mic, 4`, `overdub :mic, keep: 0.8` (with Kaede's `wear:`) on the A sample object (F12, F13, F18 free first loop).
- Footswitches: MIDI footswitch mapping to rec, overdub, undo, mute, capture; a looper line in `now` (F19, H6; round 3).
- Monitors warmed up on `arm` (F21: 15 underruns at 128 frames, each a monitor's first buffer).
- Swing-preserving quantize on `rec`/`capture` (F14).
- `take.save requires:` (F10), replay scripts accepting `-f` (F15).
- Verify fixed since round 1: tr808 tracks arm/record at live level (F2-F4, fixes-5), `disarm`/`stop` landing on the block's time and taking launch points (F6, F7), `stop :choir` with a live monitor hint (F8), master gain before the chain (F9, fixes-6), take replays at 367/368 (F11, fixes-3/7).
- The funk template's `layers` scenes: does building by scenes feel like a looper set, or does the template need a looper form (record windows as sections)?

## Questions for the round-2 panel itself
1. Do the templates' tips and mix targets match what you'd tell a newcomer?  What is missing from the data (e.g. swing amounts, microtiming offsets, arrangement energy curves, typical keys)?
2. Which template fields should a generator vary (form picks, fills per phrase, ghost-chord progressions) for endless DJ-style variations?
3. Should templates carry bus layouts (drums bus, room send) once B exists?
4. Rank again: A-E plus the new candidates (foot control, texture library, templates as generators, a second drum machine).
