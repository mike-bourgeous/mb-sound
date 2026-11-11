# 10. Sound design

Build a synth voice from oscillators, filters, and envelopes, put its
numbers on knobs, open it on the sound-design screen to shape it by ear,
and keep it in your library as an instrument.  `lesson :design` is a
guided tour of the screen.

## A voice in code

A synth voice is a sound built for one note.  `v.hz` is the note's
pitch, `v.amp_env` its loudness over time, `v.velocity` how hard it was
played.  Layer oscillators, filter them, and shape them:

<!-- check: bars=2 -->
```ruby
riff = seq(A3, C4, E4, G4, A4.n4, E4.n4).n8.loop
track(:lead) { |c|
  c.synth(voices: 4) { |v|
    (v.hz.saw + v.hz.transpose(12).square.at(0.3))
      .lp4(400 + v.env(0.002, 0.3, 0.1, 0.3) * 3000, resonance: 0.4) * v.amp_env(0.005, 0.3, 0.5, 0.4)
  }.at(-12.db)
}
bg :lead, riff
```

The filter's cutoff here is 400 Hz plus a second envelope (`v.env`)
that opens it to 3400 Hz at each note and closes in 0.3 seconds: the
bright start of a pluck.

Things to put in a voice:

- Oscillators: `saw`, `square`, `triangle`, `sine`, `pulse`; `noise`;
  `unison(5, detune: 0.2)` for width; `wavetable(...)` for shapes that
  morph (`help :wavetables`).
- FM: `v.hz.fm(v.hz.transpose(19).at(400))` (a sine changing another's
  pitch makes bells and electric pianos).
- Filters: `lp4` (warm four-pole), `diode` (squelchy, a 303's),
  `filter(:highpass, cutoff: 200)`, `formant(:a, :o)` (vowels).
- Drive: `softclip`, `shape_db(:fuzz)`.
- Movement: `4.hz.lfo.at(-0.1..0.1)` is a slow wave you can add to a
  pitch or a cutoff; `v.mod` is the keyboard's mod wheel.

## Knobs on a voice

Any number can be a knob, so you can turn it while the voice plays:

<!-- check: bars=2 -->
```ruby
knob :bright, (300.hz..6000.hz).at(1200.hz)
knob :reso, 0.4
track(:lead) { |c|
  c.synth(voices: 4) { |v|
    (v.hz.saw + v.hz.transpose(12).square.at(0.3))
      .lp4(knob(:bright), resonance: knob(:reso)) * v.amp_env(0.005, 0.3, 0.5, 0.4)
  }.at(-12.db)
}
```

<!-- check: bars=2 -->
```ruby
turn :bright, 4000, over: 2.bars
```

`learn :bright` puts it on a MIDI controller: move a knob on your
keyboard and it follows.

## The sound-design screen

<!-- check: skip opens the sound-design screen -->
```ruby
design :lead
```

`design :lead` opens the track on the sound-design screen: the voice laid
out in sections like a synth's front panel (SOURCE, FILTER, AMP, MOD,
FX), a preview of the part you picked (a filter's curve, an envelope's
shape), the voice's code, and one rendered note.  The track keeps playing
while you work.

- `s` `f` `a` `o` `x` jump to a section; Up and Down step through every
  setting; Left and Right turn it (Shift for fine steps).
- Enter types a value, `0` puts back the default, `m` learns a MIDI
  controller.
- A number written in the code (not a knob yet) shows dim; Left and
  Right make it a knob and turn it, the same sound until you move it.
- `P` shows only the knobs, side by side, like a front panel.
- `design off` puts the screen back.

Every turn is a console line: you can undo it, and it lands in your take.

`design :bass, L.inst.house_bass, riff` makes a track from a library
instrument and opens it, and `design :pad` with a name that isn't a track
yet starts from a blank voice: two morphing oscillators, FM, sync, a
filter, every number already a knob.  In the
screen, NAV `l` opens the library: `/` searches, `a` auditions, Enter
loads an instrument or effect into the track.

## Keeping a voice as an instrument

An instrument is a rack that turns notes into sound.  Name it, and save
it to your library:

<!-- check: quiet -->
```ruby
irack :glass_lead do |notes|
  knob :bright, (300.hz..6000.hz).at(1500.hz)
  notes.synth(voices: 4) { |v|
    (v.hz.saw + v.hz.transpose(12).square.at(0.3)).lp4(knob(:bright), resonance: 0.4) * v.amp_env(0.01, 0.3, 0.5, 0.4)
  }.at(-12.db)
end
save :glass_lead, rack(:glass_lead)
```

From now on it is in the library, in this console and the next:

<!-- check: bars=2 -->
```ruby
stop :lead, fade: 0
track :glass, :glass_lead
bg :glass, riff
```

<!-- check: quiet -->
```ruby
help L.inst.glass_lead
```

describes it like the built-in ones, and
`turn :"glass_lead/bright", 3000` turns its knob.

## Matching a sound by ear

The tuner helps you get close to a sound you have a recording of:

<!-- check: skip opens the tuner screen -->
```ruby
tuner 'my_references/'
```

Pick a reference (a listens to it), pick a starting voice (the library,
a blank sine, the init voice), and you are on the sound-design screen with
the reference one key away: `b` flips between your sound and the
reference at matched loudness, so you compare by ear.  `S` saves your
knobs, and `refine` lets the computer nudge your settings toward the
reference while you keep playing.  `help :hand_tune` describes every
step.

## Where next

- `help` and `help.topics` for everything else: wavetables, granular
  clouds and stretches, generative music, MIDI, tracker modules, analysis.
- `lesson` for the guided lessons.
- `demo` loads a whole example set to take apart: `tracks`, `scenes`,
  `go :groove`, `play_form demo.form`.
