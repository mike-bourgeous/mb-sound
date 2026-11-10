# 2. Playing and stopping

Keep sounds playing in the background while you type, give them names,
replace them in time, turn them up and down, and stop them gently or all
at once.

## In the background

`play` waits until its sound ends.  `bg` starts a sound and gives you the
prompt back right away, so you can keep building while it plays.  Give it
a name first:

<!-- check: bars=2 -->
```ruby
bg :drums, tr909(grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop).at(-12.db)
```

That is a drum machine playing a looping pattern (chapter 4 explains the
`x...` grids).  Now a bass line beside it:

<!-- check: bars=2 -->
```ruby
bass = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
bg :bass, bass.tone.saw.lp4(600, resonance: 0.4).at(-18.db) * bass.amp_env
```

It doesn't start the moment you press Enter: when something is already
playing, a new sound waits for the next bar line, so everything stays in
time.  The console says where it lands, such as `bg :bass lands 3:1`.

`bass.tone` is the pitch of each note in the clip, and `bass.amp_env` an
envelope that opens on each note.  Any sound can be built on them.

## Replacing a sound

Run `bg` again with the same name and the new sound takes over on the
next bar.  This is how you work: change a line, press Enter, listen.

<!-- check: bars=2 -->
```ruby
bg :bass, bass.tone.saw.lp4(1200, resonance: 0.6).at(-20.db) * bass.amp_env
```

## What is playing

- `players` lists every sound playing, by name.
- `now` shows what plays, the tempo and bar, and commands you can type
  next, filled in with your own names.

<!-- check: quiet -->
```ruby
now
```

## Tempo

`bpm 128` sets the tempo; everything follows, clips, echoes, and
wobbles alike.  `tempo 140, over: 4.bars` speeds up gradually.

<!-- check: bars=2 -->
```ruby
bpm 128
```

## Levels

Each named sound has a fader: `level :bass, -6.db` turns it down 6 dB,
`over: 2` glides there over two bars.  `mute :drums` and `unmute :drums`
silence a part and bring it back; `solo :bass` plays it alone until
`unsolo :bass`.

<!-- check: bars=2 -->
```ruby
level :drums, -4.db, over: 2
```

Everything you hear goes through the master: it sits 10 dB down, so a few
parts at full level add up without distorting.  `master_gain -6.db` moves
it.  If the whole set is too loud or quiet in your speakers, use
`help.level` instead: it changes only what you hear, never what you
record.

## Stopping

`stop :bass` fades the bass out over four bars; `stop :bass, fade: 0`
cuts it now.  `stop` alone stops the last sound you started.

<!-- check: bars=4 quiet -->
```ruby
stop :bass
```

- `outro` fades everything out over four bars.
- `panic` stops everything right away (and cancels anything waiting to
  start).  It is always safe to type.
- Ctrl-C stops a `play` and gives you the prompt back.

<!-- check: quiet -->
```ruby
outro
```

## Undo

Every command is one step you can take back: `undo` takes back the last
one on the next bar, and `redo!` puts it back.  `changes` lists what
happened and when.

## Timing

`bg`, `stop`, `level`, and most other commands take a launch point:

- `on: :beat` on the next beat, `on: :bar` the next bar (the default for
  new sounds), `on: 4` the next four-bar line.
- `in: 2.bars` two bars from now.
- `at: bar(17)` at bar 17.

```ruby
bg :bass, bass.tone.triangle.at(-12.db) * bass.amp_env, on: :beat
stop :bass, in: 8.bars
```

Next: [a song as a script](03-song-files.md), the same commands in
a file you can play and render.
