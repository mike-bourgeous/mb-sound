# 6. Effects and buses

Echoes, reverbs, chorus, drive, and dynamics go after a sound like any
other step in the chain.  Buses share one effect among many parts, and the
master shapes the whole mix.

## An effect after a sound

Effects are words you add to the end of a sound.  Start with a little
pluck line:

<!-- check: bars=2 -->
```ruby
blip = seq(E5, rest, rest, B4, rest, rest, G4, rest).n8.loop
pluck = blip.tone.triangle.at(-14.db) * blip.amp_env
bg :pluck, pluck
```

A dotted-eighth echo, repeats fading by half:

<!-- check: bars=2 -->
```ruby
bg :pluck, pluck.delay(1.n8.dotted, feedback: 0.5)
```

Delay times are note lengths, so they follow the tempo.  A tape echo with
its wobble and darkening repeats, a plate reverb, a chorus:

<!-- check: bars=2 -->
```ruby
bg :pluck, pluck.tape_echo(:dub)
```

<!-- check: bars=2 -->
```ruby
bg :pluck, pluck.reverb(:plate, mix: 0.3)
```

<!-- check: bars=2 -->
```ruby
bg :pluck, pluck.chorus.reverb(:hall, mix: 0.25)
```

Chain as many as you like, in any order: each effect hears what came
before it.

## Some of what there is

- Echoes: `delay`, `ping_pong` (bouncing left and right), `dual_delay`,
  `tape_echo(:reel)` (also `:slapback`, `:dub`), `haas` (a widener).
- Space: `reverb(:hall)` (also `:room`, `:plate`, ...; `L.fx.reverb`
  lists them), `convolve('space.wav')` for a recorded space.
- Movement: `chorus`, `phaser(:swirl)`, `flanger(:jet)`, `rotary(:whirl)`
  (a spinning speaker), `tremolo`.
- Color: `softclip` (warm drive), `clip`, `shape_db(:fuzz)`,
  `chebyshev(h2: 0.5)`, `decimate(8000)` and `quantize(6.bits)` for lo-fi.
- Dynamics: `compress`, `limit`, `duck`, `transients(attack: 6.db)`,
  `noise_gate`, `squeeze` (multiband, loud).

`help :effects` and `help :dynamics` have examples of each to try.

## How much effect

Most effects take `mix:` (0 is dry, 1 all effect).  For any effect, or a
chain of them, `blend` mixes it in:

<!-- check: bars=2 -->
```ruby
bg :pluck, pluck.blend(0.3) { |s| s.tape_echo(:dub).reverb(:hall, mix: 1) }
```

## Drive and a moving filter

A filter after drive, opened and closed by a slow wave (an LFO) locked to
the tempo, is the classic acid move:

<!-- check: bars=2 -->
```ruby
stop :pluck, fade: 0
acid = seq(A1, A1, A2, A1, C2, A1, G1, A1).n16.loop
wobble = 2.bars.lfo.at(300..2500)
bg :acid, (acid.tone.saw * acid.amp_env).softclip.lp4(wobble, resonance: 0.7).at(-16.db)
```

`2.bars.lfo` is a wave that goes around once every two bars;
`.at(300..2500)` sweeps it between those two values.  Chapter 7's knobs
let you move things like this by hand instead.

## Stereo

A sound starts in the middle.  `pan(-0.5)` moves it left (and makes it
stereo), `stereo(left, right)` gives each side its own sound, and
`width(0.6)` narrows a stereo sound.

<!-- check: bars=2 -->
```ruby
stop :acid, fade: 0
bg :pluck, pluck.pan(-0.5).reverb(:room, mix: 0.2)
bg :pad, stereo(220.hz.saw, 220.6.hz.saw).lp4(900).at(-30.db).width(0.8)
```

## Buses: one effect for many parts

A bus is a named place to send sound.  Put one reverb on a bus and send
every part to it at its own level, as on a mixing desk:

<!-- check: bars=2 -->
```ruby
stop :pad, fade: 0
bus(:verb) { |sig| sig.reverb(:hall, mix: 1) }
bg :pluck, pluck, send: { verb: -6.db }
```

The bus plays only the reverb (`mix: 1`); the part plays dry and its send
sets how much reaches the reverb.  `feed :pluck, :verb, -12.db` changes a
send later, and `buses` lists them.

## Ducking

Ducking turns a sound down while another plays, the pumping pad under a
kick drum:

<!-- check: bars=2 -->
```ruby
bg :drums, tr808(grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop).at(-16.db)
bg :pad, (A2.saw + E3.saw).lp4(900).at(-28.db).duck(:drums, only: :kick, amount: -10.db)
```

`duck(:drums, only: :kick)` listens to the kick of the part named
`:drums`, wherever it plays.

## The master

Everything ends in the master.  `master { |mix| ... }` puts effects on
the whole mix, and the mastering presets finish a song for a purpose:

- `master { |mix| mix.compress(ratio: 2).limit(ceiling: -1.db) }` glue
  and a limiter of your own.
- `master :club`, `:streaming`, `:vinyl`, `:quiet`: low end in mono,
  glue, a limiter, and a loudness that suits the place (renders reach it;
  live it is a guide).
- `master nil` takes the master effects off.

<!-- check: bars=2 -->
```ruby
master { |mix| mix.compress(ratio: 2).limit(ceiling: -1.db) }
```

<!-- check: quiet -->
```ruby
master nil
outro
```

`help :mastering` has the presets' loudness targets and how to master
like a reference track you love.

Next: [a live set](07-a-live-set.md): tracks, scenes, song forms, and
knobs.
