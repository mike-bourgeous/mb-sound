# Genre templates (`lib/mb/sound/genre.rb`, `genre/`, console `GenreMethods`)

Branch `genre-1` (2026-10-13).  Maintainer, after the persona panel: "The persona experiment was very useful. I'd like to capture the genre information as flow structures or something, and potentially repeat the experiment when there are more features."  Sources: the panel (`research-persona-panel` 0c08a17d: transcript, briefs), the personas' research notes and songs (`research-persona-edm`, `-jungle`, `-zen`, `-looper`), the merged songs (`bin/songs/tunnel_vision.rb`, `memory_card.rb`, `tin_roof.rb`, `loop_church.rb`), and their patch scripts (`bin/synths/dnb.rb`, `jungle.rb`, `ambient.rb`, `funk.rb`, `electric_pianos.rb`) and presets.

## What a template is

`genre :dnb` returns a `Genre::Template`: a frozen `Data` value holding what the panel's research said a genre is, as the library's own objects:

| field | type | example (`:dnb`) |
|---|---|---|
| `name`, `title` | Symbol, String | `:dnb`, `"Drum & bass (modern UK)"` |
| `tempo`, `tempo_range` | Numeric, Range | `174`, `170..176` |
| `meter` | `[beats, unit]` | `[4, 4]` |
| `phrases` | Array of bars | `[8, 16, 32]` |
| `key` | `[mode, root]` (`#scale` makes the Scale) | `[:minor, :f]` |
| `form` | `Form` (a `flow` block) | intro 32, build 8, drop 32 (at bar 41: the classic "drop at 33" plus a build), breakdown 16, pullup 1, drop2 32, outro 32 |
| `kits` | `{name => Sequence::Kit}` (grids, fills) | `:intro`, `:build`, `:drop` (two-step, ghosts, a `:roll` fill), ... |
| `clips` | `{name => Sequence::Clip}` | `:riff`, `:chords`, `:hook`, `:hit` |
| `roles` | `{name => Genre::Role}` | `drums: Role(:dnb_drums)`, `bass: Role(:dnb_reese, params: { cutoff: :cut }, duck: -8.db)` |
| `scenes` | `{name => {track => kit/clip name, knob => value}}` | `drop: { drums: :drop, bass: :riff, sub: :riff, cut: 2400 }` |
| `knobs` | `{name => [default, options]}` | `cut: [2400, { range: 150..8000, curve: :exp }]` |
| `pulse` | kit name whose kick row keys ducks | `:drop` |
| `mix` | `Genre::Mix` | `loudness: -10..-8, true_peak: -0.5.db, mono_below: 120, master: [[:dnb_master, [], { air: :air, drive: 8 }]], gain: 0.db` (master: steps run in order, each a preset with an `:input` or a GraphNode method with arguments: jungle's `master :compress, ...; master :at, 5.db; master :limit, ceiling: -1.db`) |
| `tips` | Array of Strings | "Drop on a 32-bar boundary for DJs ...", "Keep the sub mono ..." |

Roles name a **patch**: a preset (`presets/*.mbg.rb`, shipped with mb-sound: the genre patch scripts saved by `bin/save_presets.rb`), else a `Genre::Patches` method (a noise `riser`, from Tunnel Vision), else an `MB::Sound` method taking a MIDI source (`:tr808`, or a voice method such as `:dnb_reese_voice` once its script is loaded).  So a template plays without requiring any bin/ script, and stays data: no Procs, nothing that can't print.  Role options: `level:` (a gain, written in dB), `params:` (preset params: numbers, or Symbols naming template knobs, which the preset's param then reads: `params: { cutoff: :cut }`; round 2, after graph documents' params learned to take nodes and knob names), `filter:` (a knob name: a lowpass on the role's output that the knob drives, for patches without a fitting param, like the house stub's tine piano), `duck:` (an amount: sidechain ducking keyed by a ghost kick of `pulse`'s kick row, Kez's workaround until buses-1's bus sidechain; the ghost is a short 808 kick, `Genre::PULSE_KICK`, since the default 2.4 s decay held the bass down 6-9 dB), `q:`, `fade:`, `about:`.

## Building, composing, printing

```ruby
genre :dnb                          # the registered template
genres                              # lists them (name, title, tempo)
t = genre(:dnb, tempo: 172)         # Data#with: any field
t = genre(:dnb) { tempo 170; role :bass, :jungle_reese, level: -2.db }   # the builder, on top
t.form; t.kits[:drop]; t.scene(:drop); t.scale; t.tips
t.short                             # the form scaled to about a minute (sections, fills, phrase fills, and role bars: params / 2^n, at least 1 bar)
t.setup                             # tempo, meter, quant, knobs, master, tracks, scenes on the current Session
t.play                              # setup + play_form(t.form)
puts t.to_ruby                      # Genre.template :dnb, "..." do ... end (evaluates to an equal template)
Genre.define(:my_dnb, 'Mine') { like :dnb; tempo 168 }   # register a new one (lazy: built on first use)
```

- The builder (`Genre::Builder`, `instance_exec`) has one method per field (`tempo 174, range: 170..176`, `meter 7, 8`, `phrases 8, 16`, `key :minor, :f`, `flow do ... end`, `kit :drop, grid(...)`, `clip :riff, seq(...)`, `role :bass, :dnb_reese, level: -1.db`, `scene :drop, drums: :drop, bass: :riff`, `knob :cut, 2400, range: ..`, `pulse :drop`, `loudness`, `true_peak`, `mono_below`, `master`, `master_gain`, `tip`, `about`) plus `like :other` (start from another template) and `layers beat: :beat, bass: :bass_a, ...` (a looper's build-by-layering: one cumulative scene per layer, each named after the track it adds).  Other calls (`grid`, `seq`, `chord`, `events`, `scale`) go to `MB::Sound`, so kits and clips are written with the usual DSL; note names resolve because the template files are inside `module MB::Sound`.  Unknown builder methods raise with did_you_mean suggestions.
- Re-declaring a role, kit, clip, scene, or knob replaces it (so `genre(:dnb) { ... }` overrides parts); the form is replaced whole; `without roles: [...], scenes: [...]` removes parts (removed roles leave the scenes too); `master nil` clears the chain.
- `to_ruby` prints the builder: kits and clips through their graph-io recipes (`grid(16, kick: "X...").loop(align: :launch).fill(:roll, ...)`), the form through `Form#to_ruby`, levels as `-1.db`.  `Template#==` compares the printed code (like `Form`).
- Registered templates are built lazily (the first `genre(:x)`): building clips and forms needs `MB::Sound` loaded and a Session for form knob options, which templates don't use (section knob values live in scenes, which a template's knobs exist for).
- Scenes name kits and clips by Symbol; `Template#scene(name)` resolves them (a role-named key whose value isn't a kit or clip name is passed on: `:on`, `:off`, `nil`, `:keep`), and knob keys pass through (`cut: [2500, { from: 250, over: 8 }]`).  `Template#check` validates: every scene track is a role, every kit/clip name exists, every form section has a scene, knob keys are knobs, the tempo is in its range.

## Mono low end (round 2)

Maintainer, 2026-10-13: "Mono bass should be an option; headphones and ambient would not want it unless pressing to vinyl."  `mono_below 120` in a template makes `GraphNode#mono_below(120)` (`DynamicsMethods`: an LR4 crossover per channel, the lows averaged into one channel, the highs untouched; the sum is an allpass) the first stage of its master chain; without it the low end stays as mixed.  Decisions per genre: `:dnb` 120 Hz (club systems; the sub is mono anyway), `:jungle` 150 Hz (cut for vinyl and dubplates, from Nev's research), `:house`/`:techno` 120 Hz (club stubs); `:ambient` and `:funk` never (headphone listening, wide rooms and pads).  `Mix#report(result, data)` adds `side below 120 Hz -38.3 dB re mid (mono_below 120: mono)` (side vs mid power in the FFT bins below the template's frequency, or 120 Hz; "mono" under -30 dB; the crossover's slope leaves side content just above the frequency leaking into the bins below it, so a mono_below master measures about -35 to -40 dB, not -inf).

## The templates

Each cites the persona research it came from (the persona branches' `research.md`; tips are the panel's practical lessons).

- `:dnb` (Kez Volta, "Tunnel Vision"; research-persona-edm): 174 (170-176), phrases 8/16/32, DJ intro 32 and drop on a 32-bar line, two-step kick (1 and the "and" of 3), ghost snares, snare-roll fill every 16, Reese + separate mono sub ducked by the kick, minor 9th pads and a liquid pluck in the breakdown, pull-up bar, switch-up second drop (neuro bass), club master (glue, clip, limit): -10..-8 LUFS since patches-5 (was -8..-6), -0.5 dBTP, mono below 120 Hz.
- `:jungle` (Nev Ashdown, "Memory Card"; research-persona-jungle): 165 (155-175), the sliced-break sampler preset (`jungle_breaks`, slices on key zones: chop patterns are Notes), ride and shaker, sine sub, half-time pads and Rhodes stabs, the flute lead, long builds, breakdown with a pitched snare-roll build; vinyl-era master: -12..-9 LUFS, -1 dBTP, mono below 150 Hz.
- `:ambient` (Kaede Rowntree, "Tin Roof, Slow River"; research-persona-zen): 60 BPM (one bar is 4 s; 50-80), an arch form (emerge, drift, bloom, hush, tide, dissolve), no drums, drone + bowls on loops of incommensurable lengths in seconds (19.7, 23.3 s as whole notes at 60 BPM), the koto motif with chance notes (in quarter notes since patches-4: "Slow the koto"; about 4 notes per 8-bar pass since patches-5, was 7: "maybe half as many notes"), gong strokes (shimmer tuned -7 by default and its width a knob, `:shimmer` and `:spread`, since patches-5), a rain stick; quiet master (a limiter as a safety): -18..-16 LUFS, -1 dBTP; tips about tails, silence, and loops that must keep turning (F14).
- `:funk` (Tiko Marvell, "Loop Church"; research-persona-looper): 96 (90-100; funk 95-115, neo-soul 70-95), 2-bar loops, built by layering (beat, bass, keys, perc, then the groove), the ONE on the grid and a laid-back swung feel, Dm9 | G13 vamp, bridge, strip-down by muting layers; warm master: -13..-10 LUFS, -1 dBTP.
- `:house`, `:techno` (stubs, from general knowledge, flagged as such): 124 (118-128) and 132 (125-140), four on the floor, offbeat open hats, 16/32-bar phrases, intro/groove/breakdown/drop/outro; drums are `tr909` (drums-2, 2026-10-13), bass/stabs from existing presets.  Techno's bass is `Genre::Patches.roller` (patches-4, 2026-10-13; maintainer: "Roller sub maybe needs filtered noise and/or reverb, clashes with 808 kick"): a short sub sine with a bandpassed-noise tick on every note (24 times the note, 0.34% of the power above 1 kHz), the part above 250 Hz in a small room, ducked -9 dB under the `:peak` kick (`pulse :peak`).

## Levels and the limiter (patches-5)

Maintainer on genre :dnb (2026-10-13): "Mix needs a bit of rebalancing especially in second drop; limiter is controlling everything so relative levels seem to change when neuro stops".  Measured on the short form's stems (`/app/tmp/listening/patches-5/gr.rb`: the stems summed, run through `mono_below` and `dnb_master` offline, matching the render's loudness within 0.1 LU; peaks per 100 ms window before the clipper vs after the limiter): the clipper and limiter together held the drop 8.0 dB down (median), drop2 7.1, the outro 3.9 (so the drums and sub came up ~3 dB when the neuro stopped); the limiter alone 2.1 dB median through drop2, up to 5.5 dB on peaks.  Rebalanced (drums -1 dB, Reese -2, sub -9 (was -6), neuro -5.5 (was -1.5); `dnb_master`'s new `drive` param 8 dB, was 11): clip + limit medians drop 4.1, drop2 2.7, outro 0.8; the limiter alone 0.0-0.3 dB median and 2.6-2.9 dB at the 90th percentile of 100 ms peaks (3.3 in the 2-bar build), 4.0-4.7 dB on the single highest; -9.9 LUFS (was -7.5), so the loudness target became -10..-8.  Drive 10 measured -8.5 LUFS with the limiter's 90th percentile at 3.3-4.1 dB.  Found on the way: scene changes on a playing kit track left rows the new kit lacks playing (the hats-only breakdown kept the drop's kick and snares, the limiter taking up to 14 dB off it); Arrangement now silences them (design/notes/arrangement.md).

## Demo

`bin/songs/genre_demo.rb --genre dnb` (`-G`; `-g` is the script runner's graphviz flag) builds and plays (or renders) a template's short form, nothing else: `genre(p.genre).short(p.seconds).play`.  `--full` plays the whole form, `-s` sets the length, `--show` prints the template, `--bpm` scales the tempo; `--help` lists the genres.  Renders: `/app/tmp/listening/genre-1/`.

Measured (2026-10-13, short forms, `Mix#report` on the render; LUFS integrated, target in parentheses): dnb -7.5 (-8..-6), its drop -6.6 and drop2 -6.3 (Tunnel Vision's drop -6.8); jungle -11.5 (-12..-9; Memory Card -11.5); ambient -16.6 (-19..-16; no rain or river, so the chain drives 4 dB into its safety limiter); funk -13.8 (-14..-10); house -9.5 (-10..-8), techno about -9 (-9..-7) after 11 dB of drive (stubs).  Stem levels were set against the songs' stems (the dnb bass and sub within 1 dB of Tunnel Vision's).  A render takes 6-12 s of CPU for a minute.

Round 2 measured (renders in /app/tmp/listening/genre-1/r2/, side below the frequency re mid, round 1 without the stage -> round 2 with it): dnb -35.0 -> -38.3 dB (the sub is mono already and the Reese highpassed), jungle -33.6 -> -42.2 (150 Hz), house -49.3 -> -61.9, techno -70.0 -> -71.1; ambient -3.1 dB and funk -58.1 dB without a stage (funk renders sample-identical to round 1). Loudness moved at most 0.1 LU.

## Later

- Buses (buses-1): `duck:` becomes bus routing; mix roles (`:drums` bus, a room send for ambient) can be template data.
- `drums-2`: `tr909` for `:house`/`:techno`.
- A sampler (the panel's A): jungle's break role becomes a slice player; tempo-per-clip (D) for the record.
- Template-driven generation (picks between variations per section, `ghost_chords` over the key's progression), and section-level knob values once forms take them without a Session.
- A second persona panel uses these templates as starting points (`research/persona-panel-round2.md`).

drums-2 round 2 (2026-10-13): with the `tr909` drums the stubs' short forms fell under their targets (house -10.5 LUFS in -10..-8, techno -11.0 in -9..-7; the 808 versions were -9.5 and -8.6): the 909 kick is peakier (click and tick, accented X on every beat) for its loudness, so the limiter held the mix down and more drive barely helped (techno `at` 11 -> 15 dB: -11.0 -> -10.3).  Both masters now drive into a softclip before the limiter, as club masters do (clip, then limit; the dnb template's tip): house `compress -> at 9.db -> softclip(0.45, 0.95) -> limit` (-8.9 LUFS, -1.00 dBTP), techno `compress -> at 13.db -> softclip(0.35, 0.95) -> limit` (-8.7 LUFS, -1.00 dBTP).  The clipper raises the side below 120 Hz from about -65 to -43 dB re mid (still mono; its harmonics of stereo highs).  Roller levels against the 909 kick (techno master above; bass stem LUFS): `level: -3.db, duck: -9.db` (default) -24.1, mix -8.7; `0.db, duck: -6.db` -19.9, mix -8.5; `2.db, duck: -4.db` -16.8, mix -8.3; renders in /app/tmp/listening/drums-2/r2/ for the maintainer to pick.  After the maintainer's Bench picks (909 kick punch 0.9 / drive 0.8 / attack 0.8, hats tune -3 and short) and house's `params: { shuffle: 2 }` (the drums role passes `shuffle: 2` to `tr909`; the groove kit's closed hat gained two ghost 16ths, '5.3.5.335.3.5.32', so the shuffle is heard: its other hits are all on 8ths, which a 16th shuffle doesn't move; checked that scene swaps keep the swing), the short forms measure house -8.6 and techno -8.3 LUFS, both in their targets.
