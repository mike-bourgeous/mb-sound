# CUE and MAIN: auditioning before launch

Branch cue-1 (2026-10-18).  The maintainer picked "CUE/MAIN staging now" from the never-asked terminal UI study questions (`research-terminal-ui`, README "Staging: CUE and MAIN"): a DJ-style cue path, so a part can be heard in the headphones, in time with the set, before the audience hears it.  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## API

```ruby
cue :acid, acid_line.tone.ramp.lp4(800) * 0.4   # plays on CUE (player :"acid/cue"), MAIN untouched
cue :bass, bass_b                               # a track: its patch on the clip, on CUE
cue :lead                                       # a track not playing: its patch on its clip, on CUE
cue :drums                                      # a player already on MAIN: pre-listen (PFL), MAIN untouched
launch :acid                                    # to MAIN at the launch point: same graph, no restart
launch :bass, fade: 1.beat, on: :bar            # crossfades CUE out, MAIN in (and the old :bass out)
uncue :acid                                     # stops the cue player / ends the PFL (no names: all)
cues                                            # what plays on CUE
turn :phones, -6.db                             # phones level (a Session knob, MIDI-learnable)
turn :cue_mix, 0.5, over: 2                     # phones blend: 0 = CUE only, 1 = MAIN only
cue_output :split                               # where CUE goes (below)
```

`launch :name, ref` (a clip matrix slot, `ArrangementMethods#launch`) keeps working; `launch :name` without a ref launches a cue.  `go`/`bg` work as before and don't touch cue players.

## Routing

- A player's strip (contract K7) is fade, mute/solo, then the **route**: two gains, MAIN and CUE (`Session::Cue::Levels`, exact `Fades::Ramp`s counted in session frames).  Players with neither (every player unless cued) take the old path unchanged (`Player#cue` nil).
- `cue` starts right away unless given a launch point (`on:`/`in:`/`at:`): clips follow the timeline, so the part is in time anyway, and a `bg`-style next-bar default would leave a `cue` then `launch` in the same bar never heard (found by `cue_spec`).
- Cue players are named `:"name/cue"` (like armed monitors' `:"name/live"`): MAIN 0, CUE 1.  So a cued replacement for a playing `:bass` runs next to it, and listings show both.  `mute :bass` mutes `:"bass/cue"` too; solos don't silence cue players (a solo is about MAIN).
- MAIN 0 also zeroes everything the player sends: buses, `to:`, readers.  So renders, stems, `rec_audio`, taps, and the UI's mix ignore CUE (cue players add exactly nothing to MAIN).
- CUE is **dry**: the cue mix is the cue players' (and PFL players') post-strip sound, before buses and the master chain (the study's open question 4; dry by default, no doubled master cost).
- **Phones mix** per span: `phones = (cue * (1 - cue_mix) + main * cue_mix) * phones`, where `main` is the post-master MAIN mix (with a post-chain master gain).  `cue_mix` defaults to 0 (CUE only), `phones` to 1 (0 dB, range 0..2).  Both are Session knobs created on the first cue command (`Cue#cue_knobs`), so `turn`, `over:`, `learn`, takes, undo, and the knob panes work on them; a user knob of that name is used as it is.
- The monitor trim (`MonitorTrim`) applies to the phones channels too.

## Launch

`launch :x` is one change (`:launch`, subject `:x`) at the launch point: the track's `q:` (else the set's `quant`) for tracks, `:bar` while playing otherwise, or `on:`/`in:`/`at:`.  On its exact landing frame:
1. the players named `:x` on MAIN stop there, crossfading out over `fade:` (default the 5 ms declick);
2. `:"x/cue"` is renamed `:x` (the same Player and graph: envelopes, delays, clips carry on);
3. its MAIN gain ramps 0 -> 1 and its CUE gain 1 -> 0 over the same `fade:` (CUE stays at 1 if `:x` is pre-listened).
For tracks the Arrangement adopts the cued clip as the track's clip (`Arrangement::Cue#adopt_cue`), so scenes and listings know what the track plays.  `launch` with nothing cued raises (live: `live_error`).

PFL: `cue :x` on a playing player ramps its CUE gain to 1 (declick), MAIN unchanged; `uncue :x` back to 0.  A graph replacing `:x` keeps the PFL (it belongs to the name, like mutes).

## Undo, takes, exactness

- `cue :x, sound` is a `:bg` of `:"x/cue"` and `uncue` a `:stop` of it (the usual player undo).  PFL and launch are `:cue`/`:uncue`/`:launch` changes with subject `Cue::CueSubject`; their snapshot (`Cue::CueState`) holds the PFL set, the cue player's serial, and the `:x` PlayerState, and undoing a launch renames the player back to `:"x/cue"` (CUE again) and restores the old `:x` the usual way.
- Every gain change is a frame-counted ramp from the change's landing frame, so CUE and MAIN are the same at any buffer size (`cue_spec` renders at 800, 128, and 7 frames); takes replay the console lines and land them on the recorded frames.

## Outputs

`Session#cue_output` (console `cue_output`):
- `:auto` (default): `:ports` when the output has twice the Session's channels (MAIN 1-2, CUE 3-4), else `:off`.
- `:ports`: CUE on channels 3-4.  Open such an output with `CUE_OUTPUT=ports bin/sound.rb` (the Session then opens `MB::Sound.output(channels: 4, cue: 2)`) or, while idle, `use_output output(channels: 4, cue: 2)`.  On JACK the ports are `out_1`, `out_2`, `cue_1`, `cue_2` on the one shared client, connected to physical playback 1-4 when they exist (else the cue ports stay unconnected for qjackctl/qpwgraph); miniaudio opens a 4-channel device (an interface with 4 outs; a stereo device would downmix).  One device or client keeps both sample-locked (two devices would drift; ASRC is a later project).
- `:split` (opt-in, 2-channel): left = MAIN in mono, right = the phones mix in mono (the DJ "split cue" for a laptop and a Y-cable).
- `:phones` (opt-in, 2-channel): both channels carry the phones mix (practicing on headphones alone; turn `:cue_mix` up to hear MAIN).
- `:off`: CUE isn't heard (in the console the first `cue` warns once and names the options).
Renders never write CUE.

## Questions (cue-1, for the maintainer)

1. Names: `cue`, `uncue`, `cues`, `cue_output`, knobs `:phones`/`:cue_mix`, cue players `:"x/cue"`; `launch :x` without a ref (overloads the clip matrix's `launch :x, ref`).
2. The 2-channel default is `:off` (opt-in `:split`/`:phones`).
3. Cue players count toward CPU (they render like any player; the load pane shows them) and the `/cue` name keeps them out of scene diffs.
4. `arm`'s monitors stay MAIN; cueing an armed track (monitor on CUE while playing it in) is later.
5. CUE dry vs through a copy of the master chain; `cue_mix` default 0 vs 0.5; whether `go`/`bg` of `:x` should end `:"x/cue"`; scene cues (`cue :drop` then `launch :drop`); a CUE stem in renders.
