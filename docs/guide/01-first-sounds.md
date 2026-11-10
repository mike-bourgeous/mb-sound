# 1. First sounds

Start the console, make a tone, shape it with a filter and an envelope,
stack a chord, and play a little melody.  Everything here is typed at the
console prompt, one line at a time.

## Starting the console

From the mb-sound folder:

```sh
bin/sound.rb
```

The first time, a soft tone swells once a second while you set a
comfortable listening level with the arrow keys (Enter keeps it).  It only
turns the speakers down, never your recordings; `help.level` runs it again.

You get a Ruby prompt.  Anything Ruby can do works here, plus a few hundred
music words.  `help` shows a one-screen sheet of them, and `guide` brings
you back to this guide.

No sound card (a server, a container)?  `OUTPUT_TYPE=null bin/sound.rb`
plays silently, and the `render` command (chapter 8) writes files to listen
to anywhere.

## A tone

A pitch is a number of hertz, or a note name.  Ask it for a waveform and
you have a sound:

<!-- check: bars=1 -->
```ruby
play 220.hz.triangle.at(-20.db).for(2)
```

`.at(-20.db)` sets the level: 0 dB is as loud as an oscillator gets, every
6 dB down is half as loud.  `.for(2)` plays two seconds; without it a tone
plays until you press Ctrl-C.

Notes work the same way.  `C4` is middle C, `A3` the A below it, sharps
and flats are `Cs4` and `Bb3`:

<!-- check: bars=1 -->
```ruby
play A3.saw.at(-24.db).for(2)
```

The waveforms: `sine`, `triangle`, `saw`, `square`, and `pulse`.  Try them
all on the same note; the difference is the brightness, the harmonics
above the note.

## Filters

A filter takes some of the brightness away.  `lp4` is a warm four-pole
lowpass, the classic synth filter: the number is its cutoff in hertz, and
`resonance:` (0 to 1) makes it sing at the cutoff.

<!-- check: bars=1 -->
```ruby
play A2.saw.lp4(600, resonance: 0.5).at(-16.db).for(2)
```

The cutoff can move.  A sweep from 200 Hz up to 4 kHz over one bar and
back down over the next:

```ruby
play A1.saw.lp4(tween([200.hz, 4000.hz], 1.bar), resonance: 0.6).at(-16.db).for(2.bars)
```

## Envelopes

An envelope shapes a sound over time.  `adsr` takes the attack, decay,
sustain, and release (times in seconds, sustain as a fraction of the
peak).  On its own the note releases a moment after the attack and decay,
then ends by itself, so no `.for` is needed:

<!-- check: bars=1 -->
```ruby
play C3.saw.lp4(1500).adsr(0.005, 0.4, 0.2, 0.5).at(-14.db)
```

A short attack and no sustain make a pluck; a slow attack makes a swell:

<!-- check: bars=3 -->
```ruby
play (C4.triangle + G4.triangle).adsr(1.5, 0.5, 0.7, 2, hold: 3).at(-24.db)
```

## Chords and layers

Add sounds with `+`.  Three triangles make a chord:

<!-- check: bars=1 -->
```ruby
play (A3.triangle + C4.triangle + E4.triangle).at(-28.db).for(2)
```

Detuned copies of one oscillator make it wide and thick, the sound of a
supersaw.  `unison(5)` plays five copies, `detune:` spreads them in pitch,
and `spread:` across the stereo field:

<!-- check: bars=1 -->
```ruby
play A2.saw.unison(5, detune: 0.2, spread: 0.6).lp4(1800).at(-26.db).for(2)
```

And noise is a sound too: `noise` is white noise, `noise.lp4(800)` a dark
rumble, wind if the cutoff moves.

<!-- check: bars=1 -->
```ruby
play noise.lp4(800).at(-8.db).for(2)
```

## A melody

`seq` writes notes in order and `.n8` makes them eighth notes.  Played on
its own, a melody plays on a soft default synth:

<!-- check: bars=1 -->
```ruby
play seq(A3, C4, E4, A4, G4, E4, C4, E4).n8, gain: -14.db
```

`rest` (or `R`) leaves a gap, and a note can carry its own length:
`seq(A3, rest, C4.n4, E4).n8`.  Chapter 4 is all about clips like this
one: loops, drums, transposing, swing.

## Getting help

- `help` is the one-screen sheet; `help :filters` is a topic with
  examples, and `help(:filters).try` plays the first one.
- `help :lp4` shows one command: what it does and every option.
- `help /reverb/` searches everything for a word.
- `lesson` lists the guided lessons, which check each step as you go.

Typos are forgiving: `A3.saww` answers "did you mean saw?".

Next: [playing and stopping](02-playing.md), where sounds
keep playing in the background while you type.
