# 7. A live set

Tracks hold a sound for each part, scenes say what every track plays, and
a song form plays the scenes in order.  Knobs move things by hand, and the
cue lets you hear a part in your headphones before the audience does.
`lesson :set` walks through the same ideas with checks at each step.

## Tracks

A track is a named part with a sound waiting for notes.  The block builds
the sound from whatever clip the track is given (`k` for a kit of drum
rows, `c` for notes):

<!-- check: quiet -->
```ruby
track(:drums) { |k| tr808(k).at(-15.db) }
track(:lead) { |c| c.tone.triangle.at(-18.db) * c.amp_env }
```

A library instrument can be the sound instead.  Library instruments play
at full level, so give the track a level:

<!-- check: quiet -->
```ruby
track :bass, :house_bass
level :bass, -20.db
```

Give a track a clip and it plays, starting on the next bar:

<!-- check: bars=2 -->
```ruby
beat = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop
bg :drums, beat
```

`tracks` lists them, `untrack :lead` removes one.

## Scenes

A scene is a moment of the song: which clip each track plays.  Tracks a
scene leaves out stop (ringing out naturally).

<!-- check: quiet -->
```ruby
riff = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.loop
tune = seq(E4, rest, G4, A4, rest, G4, E4, D4).n8.loop
full = grid(16, kick: 'x...x...x...x...', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.x.').loop

scene :intro, drums: beat
scene :verse, drums: beat, bass: riff
scene :chorus, drums: full, bass: riff, lead: tune
```

`go` launches a scene on the next bar:

<!-- check: bars=2 -->
```ruby
go :verse
```

<!-- check: bars=2 -->
```ruby
go :chorus
```

- `go :intro, in: 2.bars`, `go :chorus, at: bar(17)` pick when.
- `scenes` lists them, with the one playing marked.
- `undo` goes back to what played before, on the next bar.

## A song form

`flow` plays scenes in order, each for a number of bars, and you steer it
while it plays:

<!-- check: bars=4 -->
```ruby
flow do
  intro 2
  verse 4
  label :top
  chorus 4
  verse 4
  goto :top, times: 1
  chorus 8
end
```

Each line names a scene and how many bars it lasts.  `label` and `goto`
repeat a part (`times: 1` once more, then on).  While it plays:

- `loop!` keeps repeating the section playing now; `onward` goes on.
- `skip` jumps to the next section, `goto :top` to a label.
- `finish` plays to the end, `outro` fades out from here.
- `flow` alone shows where you are and what comes next.

A form starts playing as soon as you define it (on the next bar if
something is playing).  `pause` pauses and resumes it; once it has
ended, `start` plays it again.

## Knobs

A knob is a named value you can turn while the music plays.  Use it in a
sound wherever a number goes:

<!-- check: bars=2 -->
```ruby
knob :cut, (200.hz..4000.hz).at(600.hz)
track(:lead) { |c| c.tone.saw.lp4(knob(:cut), resonance: 0.5).at(-22.db) * c.amp_env }
```

<!-- check: bars=2 -->
```ruby
turn :cut, 3000, over: 2.bars
```

- `turn :cut, 1200` jumps; `over:` glides.  Knobs keep their units: this
  one turns in hertz.
- A library instrument's settings are knobs already:
  `turn :"bass/cutoff", 400`.
- `knobs` lists them all.  `snap :bright` saves every knob's position,
  `recall :bright, over: 4.bars` goes back to it.
- `learn :cut` connects the next MIDI controller you move to the knob.

## Muting, soloing, and levels

`mute :lead` and `unmute :lead`, `solo :bass` and `unsolo :bass` (all
with a short fade), `level :drums, -3.db, over: 2`.

## Hearing it first

`cue` plays a part only in your headphones, in time with the set, and
`launch` brings it out to the speakers on the next bar.  With a
four-channel audio interface the cue gets its own pair of outputs; on a
plain stereo output, cueing splits it, the set in mono on the left and
your cue on the right (`cue_output :off` turns that off).

<!-- check: bars=2 -->
```ruby
cue :pad, (seq(A3, C4, E4).n1 & seq(E4, G4, A4).n1).loop.synth(voices: 4) { |v| v.hz.saw.lp4(1200) * v.amp_env(0.5, 0.5, 0.7, 1) }.at(-28.db)
```

<!-- check: bars=2 -->
```ruby
launch :pad
```

`cue :drums` listens to a part already playing; `uncue` ends it.
`help :cue` explains the outputs.

## Playing a MIDI keyboard into a track

Plug in a keyboard and `arm :lead`: what you play goes through the lead
track's sound, in time with the set.  `disarm` stops listening.  No
keyboard?  The terminal screen has one (chapter 9), and a polyphonic
track can be any instrument:

<!-- check: skip needs a MIDI keyboard -->
```ruby
track :keys, :tine_piano
level :keys, -12.db
arm :keys
```

Chapter 8 records what you play into clips.

## In a song file

Everything above works in a song file (chapter 3): define the tracks and
scenes and the flow, and `ruby song.rb` plays the form.

<!-- check: script -->
```ruby
require 'mb/sound/dsl'

song_script(bars: 20) do
  bpm 122
  track(:drums) { |k| tr808(k).at(-12.db) }
  track(:bass) { |c| c.tone.saw.lp4(700, resonance: 0.4).at(-12.db) * c.amp_env }
  track(:lead) { |c| c.tone.triangle.at(-14.db) * c.amp_env }

  beat = grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop
  full = grid(16, kick: 'x...x...x...x...', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.x.').loop
  riff = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.loop
  tune = seq(E4, rest, G4, A4, rest, G4, E4, D4).n8.loop

  scene :intro, drums: beat
  scene :verse, drums: beat, bass: riff
  scene :chorus, drums: full, bass: riff, lead: tune
  scene :outro, lead: tune

  flow do
    intro 4
    verse 4
    chorus 8
    outro 4
  end
end
```

`ruby song.rb --from chorus -o chorus.flac` renders only the chorus, as
it sounds in the whole song.

Next: [recording and rendering](08-recording-and-rendering.md).
