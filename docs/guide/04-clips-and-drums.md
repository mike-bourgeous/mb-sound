# 4. Clips, sequences, and drums

Clips are notes in time: melodies, bass lines, chords, and drum patterns.
Write them, loop them, change them, and play them on a synth or a drum
machine.

## Writing notes

`seq` lists notes in order.  The length after it applies to every note
that doesn't have its own:

- `.n1` whole notes, `.n2` halves, `.n4` quarters, `.n8` eighths,
  `.n16` sixteenths; `1.n8.dotted` and `.triplet` lengths work too.
- `A3.n4` is one note a quarter long; `rest` (or `R`) is a gap.
- Square brackets make a chord: `seq([A3, C4, E4], [F3, A3, C4]).n2`.

<!-- check: bars=1 -->
```ruby
riff = seq(A3, C4, E4, rest, G4.n4, E4, C4).n8
play riff, gain: -14.db
```

A clip plays once; `.loop` repeats it forever and `.repeat(4)` four times.
`riff.show` prints it as a grid, `riff.show(:roll)` as a piano roll.

<!-- check: quiet -->
```ruby
puts riff.show
```

## Changing clips

Clips never change in place: every change gives you a new clip, so you
can keep the original.

- `riff.transpose(5)` up five semitones (`transpose(-12)` an octave down).
- `riff.swing(0.6)` swung eighths; `riff.humanize` a little looser.
- `riff.reverse`, `riff.rotate(1.n8)` (shift around the loop).
- `riff.halftime`, `riff.doubletime`.
- `riff.chance(0.7)` plays each note 70% of the time.
- `seq(riff, other)` plays one clip after the other, `riff * 2` twice,
  and `riff & other` both together.

<!-- check: bars=2 -->
```ruby
play seq(riff, riff.transpose(5)).swing(0.6), gain: -14.db
```

## Chords

`chord(:min7, root: :d)` is a chord by name; put chords in a `seq` like
notes.  Arpeggiate them with `arp`:

<!-- check: bars=2 -->
```ruby
chords = seq(chord(:min7, root: :d), chord(:dom7, root: :g)).n1.loop
bg :keys, chords.synth(voices: 6) { |v| v.hz.triangle * v.amp_env(0.01, 0.3, 0.6, 0.8) }.at(-18.db)
```

<!-- check: bars=2 -->
```ruby
bg :keys, chords.arp(:up, 16).synth(voices: 4) { |v| v.hz.saw.lp4(1500) * v.amp_env(0.005, 0.15, 0.2, 0.1) }.at(-20.db)
```

## Playing a clip on a sound

There are two ways to turn notes into sound:

- One voice, the classic monophonic synth: `clip.tone` is the pitch
  of the current note, `clip.amp_env` an envelope that opens on each note.
  `bass.tone.saw.lp4(600) * bass.amp_env` is a bass synth.
- Many voices, for chords and overlapping notes: `clip.synth(voices: 6)
  { |v| ... }` builds one voice per note from the block, where `v.hz` is
  the pitch and `v.amp_env(attack, decay, sustain, release)` the
  envelope.

Inside a voice, `v.velocity` is how hard the note was played (0 to 1),
handy for brightness: `.lp4(400 + v.velocity * 3000)`.

<!-- check: quiet bars=1 -->
```ruby
stop :keys, fade: 0
```

## Drums

`grid` writes drum patterns, one row per drum.  Each character is one
step (a sixteenth by default):

- `x` a hit, `X` an accent, `.` nothing, `1` to `9` softer hits,
  `?` a hit half the time, `f` a flam.
- Row names: `kick`, `snare`, `clap`, `rim`, `hat`, `open_hat`,
  `low_tom`, `mid_tom`, `high_tom`, `crash`, `ride`, `cowbell`, and more
  (`bd`, `sd`, `oh` short names work too).

`tr808` and `tr909` are drum machines that play a grid:

<!-- check: bars=2 -->
```ruby
beat = grid(16,
  kick:  'x...x...x...x...',
  snare: '....x.......x...',
  hat:   'x.x.x.x.x.x.x.x.',
  oh:    '..............x.').loop
bg :drums, tr808(beat).at(-14.db)
```

Change the pattern and run `bg` again; it takes over on the next bar:

<!-- check: bars=2 -->
```ruby
beat = grid(16,
  kick:  'X..x..x...x..x..',
  clap:  '....X.......X...',
  hat:   'x.xxx.xxx.xxx.xx',
  oh:    '..x...x...x...x.').loop
bg :drums, tr909(beat, shuffle: 2).at(-16.db)
```

`shuffle:` (0 to 6) swings the machine; grids take the clip changes
above too (`beat.swing(0.6)`, `beat.humanize`, `beat.reverse`).

`euclid(5, 16)` spreads five hits as evenly as possible over sixteen
steps, a source of rhythms from all over the world:

<!-- check: bars=2 -->
```ruby
bg :perc, tr808(grid(16, cowbell: euclid(5, 16), rim: euclid(3, 8)).loop).at(-24.db)
```

## Your own drum kit

`kit` builds drums from pieces: a body that falls in pitch, clicks,
noise, metal, and FM, or borrows voices from the machines.

<!-- check: bars=2 -->
```ruby
stop :perc, fade: 0
bg :drums, kit(grid(16, kick: 'X..x..x...x..x..', snare: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) {
  voice(:kick, tune: 45) { |h| h.body(h.tune, decay: 0.4, sweep: 4).softclip(0.6) + h.click(0.3) }
  voice(:snare) { |h| h.noise(decay: 0.15, highpass: 2000) * 0.5 + h.body(190, decay: 0.08) * 0.4 }
  tr909 :closed_hat
}.at(-14.db)
```

## Patterns that write themselves

When you want variation without writing every bar:

- `melody(scale(:minor_pentatonic, :a).weights, 8, range: A3..A5)` makes
  an eight-note tune from a scale that comes out the same every time (the
  seed decides; `seed 3` before it gives another).
- `beats(16) { ... }` is a drum pattern that changes a little every bar.

<!-- check: bars=2 -->
```ruby
tune = melody(scale(:minor_pentatonic, :a).weights, 8, range: A3..A5).loop
bg :lead, tune.synth(voices: 2) { |v| v.hz.triangle * v.amp_env(0.005, 0.2, 0.3, 0.2) }.at(-18.db)
```

<!-- check: bars=2 -->
```ruby
groove = beats(16, hold: 2) do
  kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
  clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
  hat euclid(10, 16), mutate: 0.5, level: 0.7
end
bg :drums, tr909(groove).at(-20.db)
```

`help :generative` has much more: keys that change, phrases that come
back, rhythms steered by a knob.

## More

- `help :sequences`, `help :drums`, `help :generative`
- MIDI files become clips too: `midi_clip 'song.mid', track: 'Bass'`
  (`help :midi_files`).

Next: [instruments and the library](05-instruments-and-the-library.md).
