# 5. Instruments and the library

mb-sound comes with instruments, effects, drum machines, and pattern
generators, all in one library you can search, audition, and play your
own notes on.  Your own sounds go in the same library when you save them.

## Looking around

The library has a head for each kind of thing.  Type one to list what is
there:

- `L.inst` instruments, `L.fx` effects, `L.kit` drum machines,
- `L.gen` pattern generators, `L.flow` song forms that write themselves,
- `L.master` mastering chains, `L.all` everything.

Each word after a head narrows it down: `L.fx.reverb` lists the reverbs,
`L.fx.reverb.hall` is one of them.  In the console, Tab completes the
names.

<!-- check: quiet -->
```ruby
L.fx.reverb
```

`find` searches names, descriptions, and tags, best matches first:

<!-- check: quiet -->
```ruby
find 'warm bass'
```

`help L.inst.house_bass` describes one entry: what it is, its settings,
and lines that use it.

## Listening

- `audition L.inst.house_bass` plays an instrument's demo phrase in time
  with whatever is playing (in your headphones if you have a cue output,
  chapter 7); `audition off` stops it.
- `play L.inst.tine_piano` plays the demo phrase and waits for it.
- `play L.fx.hall` plays a short mix of drums, bass, and keys through an
  effect.

<!-- check: quiet bars=2 -->
```ruby
audition L.inst.house_bass
```

<!-- check: quiet -->
```ruby
audition off
```

## Playing your notes on an instrument

An instrument takes a clip (or a live keyboard, chapter 7) and plays it:

<!-- check: bars=2 -->
```ruby
riff = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.loop
bg :bass, L.inst.house_bass.(riff).at(-14.db)
```

Library instruments play at full level, so give them a level (`.at`) to
mix them with the rest.  Their settings go after the clip:

<!-- check: bars=2 -->
```ruby
bg :bass, L.inst.house_bass.(riff, cutoff: 500, env: 4).at(-14.db)
```

Chords work the same way on a polyphonic instrument:

<!-- check: bars=2 -->
```ruby
chords = seq(chord(:min7, root: :a), chord(:maj7, root: :f)).n1.loop
bg :keys, L.inst.tine_piano.(chords).at(-22.db)
```

On a track (chapter 7) an instrument's settings become knobs you can
turn while it plays.

## Effects from the library

An effect goes after a sound.  `then` hands the sound to it:

<!-- check: bars=2 -->
```ruby
bg :keys, L.inst.tine_piano.(chords).at(-25.db).then(&L.fx.hall)
```

The same effects are also plain commands with their presets as names:
`.reverb(:hall)`, `.chorus`, `.tape_echo(:dub)`.  Chapter 6 is about
effects.

## Struck things and booms

Every resonator in the library (bars, bells, bowls, marimbas, glass) is
an instrument too: notes strike it.  (The first line fades out the bass
and keys, to hear it alone.)

<!-- check: bars=2 -->
```ruby
stop :bass, :keys
bg :bells, L.inst.marimba.(seq(C5, E5, G5, C6).n8.loop).at(-16.db)
```

`boom(G1)` is one cinematic boom; `L.inst.boom` lists the kinds.

## Pattern generators

`L.gen` holds patterns that play differently every bar, steered by a few
settings, and the same way every time for the same seed:

<!-- check: bars=2 -->
```ruby
stop :bells, fade: 0
bg :drums, tr909(L.gen.techno_beat(seed: 3, energy: 0.4)).at(-18.db)
```

`L.gen.techno_beat(seed: 4)` is another take of it.  On a track, `energy`
and the other settings become knobs (chapter 7).

## Samples

A Sample is a sound in memory: a file, a bounce of anything you can play,
or a recording.

- `Sample['loop.wav']` reads a file (any format ffmpeg reads).  Loops
  with a tempo in their name or metadata know it (`.bpm`), and
  `.follow` plays them in time at any tempo.
- `bounce(2.bars) { ... }` renders any sound into a Sample.
- `breakbeat(:jungle)` is a synthesized break that comes with mb-sound.

Samples cut into slices and play back as clips (`help :sampler` has the
whole story, `lesson :chop` walks through it):

<!-- check: bars=2 -->
```ruby
stop :drums, fade: 0
brk = breakbeat(:jungle).slices(16)
bg :break, brk.chop(0, 1, 4, 2, 8, 9, 4, 6).loop.sampler(brk).at(-16.db)
```

`chop` takes slice numbers in the order to play them, one per
sixteenth.

SoundFont files (`.sf2`) are instruments too: `sf2('font.sf2', 0)` is
its first program (a GM piano in most fonts), played like any
instrument (`help :soundfonts`).

## Saving your own

`save` keeps any sound under a name; it shows up in the library like the
built-in ones.

<!-- check: quiet -->
```ruby
save :fat_bass, 55.hz.saw.unison(3, detune: 0.2).lp4(700, resonance: 0.4).at(-17.db)
```

<!-- check: bars=2 -->
```ruby
stop :break
bg :mine, preset(:fat_bass).until(2.bars)
```

- `save` never overwrites; `save!` replaces, `save :fat_bass, g, bump:
  true` saves `:fat_bass_v2`.
- `save :fat_bass, g, tags: %i[bass dark], about: 'a thick saw bass'`
  helps `find`.
- Saves go to your own shelf of presets, which keeps every version (it is
  a git repository).  When you work in a song folder with its own
  `presets/` folder, they go there instead.

`help :library` and `help :presets` have the details: shelves, library
files, and saving whole sets.

Next: [effects and buses](06-effects-and-buses.md).
