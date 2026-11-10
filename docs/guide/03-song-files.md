# 3. A song as a script

The console is for trying things; a file is for keeping them.  The same
commands work in a Ruby file, which plays from the command line, renders
to a sound file, and takes options like a little program.

## A song file

Save this as `song.rb`:

<!-- check: program -->
```ruby
require 'mb/sound/dsl'

bpm 124
bass = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.repeat(2)
bg :bass, bass.tone.saw.lp4(900, resonance: 0.4).at(-14.db) * bass.amp_env
bg :hat, tr909(grid(16, hat: 'x.x.x.x.x.x.x.xx').loop).at(-12.db).until(2.bars)
```

and play it:

```sh
ruby song.rb
```

(Working inside the mb-sound folder itself?  Use `bundle exec ruby
song.rb`.)

The first line gives the file every console command and note name.  The
program ends when everything has finished playing: `.repeat(2)` plays the
bass line twice, and `.until(2.bars)` stops the hats after two bars.  A
`.loop` without an end plays until Ctrl-C, and the program says so when it
starts.

## A song with a length

`song_script` wraps a song so it knows how long it is, and it gets a set
of command line options for free: render to a file, play part of it,
change the tempo.  Save this as `song.rb`:

<!-- check: script -->
```ruby
require 'mb/sound/dsl'

song_script(bars: 16) do
  bpm 118

  beat = grid(16, kick: 'x...x...x...x...', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.x.').loop
  bass = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.loop
  chords = (seq(A3, F3, C4, G3).n1 & seq(C4, A3, E4, B3).n1 & seq(E4, C4, G4, D4).n1).loop

  bg :pad, chords.synth(voices: 6) { |v| v.hz.saw.unison(3, detune: 0.15).lp4(1400) * v.amp_env(0.3, 0.5, 0.7, 1.5) }.at(-24.db)
  at_bar(5) { bg :drums, tr808(beat).at(-10.db) }
  at_bar(9) { bg :bass, bass.tone.saw.lp4(700, resonance: 0.4).at(-12.db) * bass.amp_env }
  at_bar(15) { outro fade: 2 }
end
```

Some new words here:

- `chords` stacks three clips with `&`, one note of each chord per clip,
  a chord every bar (`.n1`, a whole note).
- `synth(voices: 6)` plays a clip with chords on a polyphonic synth: the
  block builds one voice, where `v.hz` is the note's pitch and
  `v.amp_env(attack, decay, sustain, release)` its envelope.
- `at_bar(5) { ... }` runs the commands inside at the start of bar 5:
  the drums come in at bar 5, the bass at 9, and everything fades out from
  bar 15.

Now from the command line:

```sh
ruby song.rb                    # plays all 16 bars
ruby song.rb -o song.flac       # renders it to a file (as fast as it can)
ruby song.rb -o song.wav --stems stems/   # also one file per part
ruby song.rb --bars 4           # only the first four bars
ruby song.rb --bpm 100          # slower
ruby song.rb --help             # every option
```

A render sounds the same as playing; it just doesn't wait for real time,
and it needs no sound card.  `.flac`, `.wav`, `.mp3`, and anything else
ffmpeg knows work as file names.

## Your own options

Give `song_script` settings of your own and they become options too.
Each one is a default value, a description, and optionally a short flag:

<!-- check: script -->
```ruby
require 'mb/sound/dsl'

song_script(bars: 8, cutoff: [700, 'Bass filter cutoff in Hz', '-c'], root: [A1, 'Lowest note of the bass']) do |p|
  bass = seq(p.root, rest, p.root, p.root.transpose(3), rest, p.root.transpose(7)).n8.loop
  bg :bass, bass.tone.saw.lp4(p.cutoff, resonance: 0.4).at(-12.db) * bass.amp_env
  at_bar(7) { outro fade: 2 }
end
```

```sh
ruby song.rb -c 1500            # a brighter bass
ruby song.rb --root E1 -o low.flac
```

`p.cutoff` and `p.root` read the settings inside the song.

## Things happening over time

Inside a song (or at the console), these schedule what happens next:

- `at_bar(9) { ... }` at the start of bar 9.
- `after(2) { ... }` two bars from now; `after(1.beat) { ... }` a beat.
- `every(4) { ... }` every four bars (it gives back a handle with
  `.cancel`).
- `tempo 140, over: 8.bars` speeds up gradually.

```ruby
every(1) { bg :ping, A5.sine.adsr(0.002, 0.5, 0, 0.3).at(-14.db) }
```

For songs with verses and choruses, chapter 7 has tracks, scenes, and
song forms that play through themselves; they work in a song file just
the same.

Next: [clips, sequences, and drums](04-clips-and-drums.md).
