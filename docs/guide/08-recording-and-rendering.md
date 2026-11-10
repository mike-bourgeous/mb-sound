# 8. Recording and rendering

Keep what you played: the take remembers every line you typed and when,
your keyboard playing becomes clips, the mix goes to a file live, and any
song or sound renders to a file offline.

## The take: everything you typed

From the moment the console starts, it keeps a take: every command and
when it landed in the music.  Save it, and you have a script that
plays your session again, line by line, at the same moments:

<!-- check: quiet -->
```ruby
bg :drone, (A2.saw + E3.saw).lp4(700).at(-26.db)
take.save 'jam.rb'
```

`take.save` without a name saves to your takes folder and prints where;
`take.save note: 'the good one'` adds a note to the file.

From a shell, the saved take plays again or renders:

```sh
ruby jam.rb                     # plays the session again
ruby jam.rb -o jam.flac         # renders it to a file
```

The console also saves the take every minute, so a crash never loses a
session.

## Recording a keyboard into a clip

With a MIDI keyboard (or the screen's keyboard, chapter 9), arm a track
and record into it:

<!-- check: skip needs a MIDI keyboard -->
```ruby
track(:lead) { |c| c.synth(voices: 4) { |v| v.hz.saw.lp4(1500) * v.amp_env } }
arm :lead
rec 4                 # records the next 4 bars as a looping clip
```

- `rec 4` records four bars from the next bar line and loops them on the
  track when done.
- `capture :lead` keeps what you just played, without having pressed
  record first: the last phrase (or `capture :lead, 4`, the last four
  bars) loops on the track.
- `captures` lists the recordings; each is a clip like any other
  (`captures[:lead_1].transpose(12)`).
- `disarm` stops listening to the keyboard.

`lesson :record` goes through it step by step.

## Recording the mix

`rec_audio` records whatever you hear (the master) to a file until
`stop_rec_audio`:

<!-- check: quiet bars=2 -->
```ruby
rec_audio 'live_jam.flac'
```

<!-- check: quiet -->
```ruby
stop_rec_audio
```

`capture_audio(4.bars)` records the next four bars into a Sample in
memory instead, ready to slice and play back (chapter 5).

## Rendering

`render` plays a sound or a whole song into a file as fast as the
computer can, with no sound card needed:

<!-- check: quiet -->
```ruby
riff = seq(A1, rest, A1, C2, rest, E2, D2, rest).n8.loop
render 'bass.flac', riff.tone.saw.lp4(800).at(-12.db) * riff.amp_env, bars: 4
```

A block renders everything it starts, so a whole arrangement fits:

<!-- check: quiet -->
```ruby
render 'groove.wav', bars: 8 do
  bpm 120
  bg :drums, tr808(grid(16, kick: 'x...x...x...x...', hat: '..x...x...x...x.').loop).at(-12.db)
  bg :bass, riff.tone.saw.lp4(800).at(-12.db) * riff.amp_env
end
```

Useful options:

- `stems: 'stems/'` also writes one file per part, lined up from the
  start, for mixing elsewhere.
- `master: :streaming` masters the render to a loudness target
  (`:club`, `:vinyl`, `:quiet` too; chapter 6).
- `loudness: -14` makes the file that loud (in LUFS).
- `report: :tracks` prints each part's loudness and peak.

The file's extension picks its format: `.flac`, `.wav`, `.mp3`, `.ogg`,
and anything else ffmpeg writes.

Song files render with `-o` (chapter 3), with the same choices as
options: `--stems DIR`, `--master club`, `--report`, `--from chorus`.

## How loud is it?

<!-- check: quiet -->
```ruby
l = loudness 'groove.wav'
[l.lufs.round(1), l.true_peak.round(1)]
```

gives the loudness the way streaming services measure it (LUFS) and the
true peak in dB.  Around -14 LUFS is typical for streaming, louder for
clubs; keep the true peak under -1 dB.

## Saving a whole set

`save :my_set, set` saves the tracks, scenes, knobs, buses, and song form
as a document; `preset :my_set` loads it back into the console, ready to
`go :verse` or `start` its form.  `help :presets` has the details.

Next: [the screens](09-the-screens.md).
