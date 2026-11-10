# 9. The screens

The console can show what is playing while you type: a dashboard band
under the prompt, or a whole screen of panes with meters, scopes, the
clips of your set, and a keyboard to play.  Plots draw sounds in the
terminal.

## The dashboard band

<!-- check: skip draws on the terminal -->
```ruby
ui
```

`ui` puts a band of live information under the prompt: the bar and
tempo, the song form, the tracks playing, changes waiting to land, master
meters, and a scope.  `ui :deck` is taller (knobs and how hard the
computer works), `ui :mini` one line, `ui off` hides it.

## The whole screen

`ui :tiles` takes the whole terminal: the console in one pane, the set
around it.  Other layouts:

- `ui :session` the set: a grid of every track's clips by scene (the clip
  matrix), the clip under the cursor as a piano roll, racks of knobs,
  buses.
- `ui :mixer` buses and the master with meters.
- `ui :keys` the console over a playable keyboard.
- `ui :studio`, `ui :wall` more at once, for big terminals.
- `ui :sound` sound design (chapter 10).

`help :ui` lists every layout and pane, and the keys.

## Moving around: NAV mode

Ctrl-] switches to NAV mode, where keys move between panes instead of
typing:

- numbers or arrows pick a pane; Enter goes into it, Esc comes back out;
- the letter beside a pane's number jumps straight in: `i` the console,
  `k` the keyboard, `a` the clips;
- Ctrl-W z zooms a pane and back;
- `?` lists every key.

In the clip grid, the arrows move, Enter launches the clip under the
cursor, `g` its whole scene, `x` stops the track, and `+` `-` transpose.
Every key types one console line for you, so it shows up in the console,
can be undone, and lands in your take like anything typed.

## The keyboard

F2 (or `keys`) plays the screen's keyboard with your computer keys, into
whatever track is armed (chapter 7), or a default sound when nothing is.
The bottom row of letters (z x c v b n m) plays the white keys from C,
with s d g h j as the black keys between them, and q w e r t y u plays
an octave higher with the number keys as its black keys, as in most
music software.  Enter captures what you just played into the armed
track, and Tab writes notes step by step into a clip.

`ui.keyboard.scale = scale(:dorian, :d)` locks the keys to a scale: every
white key the next note of it, so nothing played is ever a wrong note.

Most terminals send no key-up, so notes are a fixed length there
(`ui.keyboard.tap = 0.5`); terminals with the kitty keyboard protocol
(kitty, WezTerm, Ghostty, foot, iTerm2 with its setting) end notes when
you let go.

## Songs and files on their own screen

- `ruby song.rb --ui` plays a song file on a screen of its own: Space
  pauses, Left and Right move a bar, Up and Down a section, q quits.
- `bin/play.rb file.flac tune.mod song.mid` plays sound files, tracker
  modules, and MIDI files, each on a screen made for it.

## Plots

Plots draw in the terminal (or as images in terminals that show them):

<!-- check: quiet -->
```ruby
plot 110.hz.saw.lp4(800, resonance: 0.6), samples: 1200
```

- `plot sound` the waveform; `spectrum sound` its harmonics.
- `spectrogram 'song.flac'` brightness over time.
- `vis` the live mix on a big scope until Ctrl-C; `vis spectrum: true`
  its spectrum.
- `chart { ... }` builds your own charts, saved as SVG or PNG.

With the tiles up, plots show in a pane beside the console.

## Notes to yourself

`ui.note 'the hats are too bright here'` keeps a note with what was
playing and what the screen showed, in a dated file it names.  Handy at a
rehearsal: write it down without stopping.

## Help on screen

With the tiles up, `help` pages open in a pane you can scroll (j and k,
`/` to search, q to close), so the set stays in view.

Next: [sound design](10-sound-design.md).
