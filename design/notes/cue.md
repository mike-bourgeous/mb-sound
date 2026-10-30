# CUE and MAIN: auditioning before launch

Branch cue-1 (2026-10-18).  The maintainer picked "CUE/MAIN staging now" from the never-asked terminal UI study questions (`research-terminal-ui`, README "Staging: CUE and MAIN"): a DJ-style cue path, so a part can be heard in the headphones, in time with the set, before the audience hears it.  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## API

```ruby
cue :acid, acid_line.tone.saw.lp4(800) * 0.4   # plays on CUE (player :"acid/cue"), MAIN untouched
cue :bass, bass_b                               # a track: its patch on the clip, on CUE
cue :lead                                       # a track not playing: its patch on its clip, on CUE
cue :drums                                      # a player already on MAIN: pre-listen (PFL), MAIN untouched
launch :acid                                    # to MAIN at the launch point: same graph, no restart
launch :bass, fade: 1.beat, on: :bar            # crossfades CUE out, MAIN in (and the old :bass out)
uncue :acid                                     # stops the cue player / ends the PFL (no names: all)
cues                                            # what plays on CUE
turn :phones, -6.db                             # phones level (a Session knob, MIDI-learnable)
turn :cue_mix, 0.5, over: 2                     # phones blend: 0 = CUE only, 1 = MAIN only
cue_mix 0.3, save: true                         # set it and keep it as your starting blend
cue :drop                                       # a scene: cues every track whose clip it changes
launch :drop                                    # the scene, with those cued graphs taking over
cue_output :split                               # where CUE goes (below)
```

`launch :name, ref` (a clip matrix slot, `ArrangementMethods#launch`) keeps working; `launch :name` without a ref launches a cue.  `bg :x`/`go` starting a new `:x` also stop `:"x/cue"` at the same time (declick; journaled `:stop`, undone with the command; maintainer 2026-10-18).  A queued `:launch` counts as a start (`Changes::START_KINDS`), so `stop :x` for now cancels it and `go` leaves a track alone whose cued clip is about to launch.

Launching what was cued (omnibus15, from the maintainer's take of 2026-10-27: `cue :pad` on a playing track, then `launch`, `launch :pd`, `launch :pad`: "it thinks I didn't cue pad?"): `cue :pad` of a playing part is a pre-listen (PFL), not a cue player, so `launch :pad` used to say "Nothing cued as :pad".  Now `launch :name` of a pre-listened part (`Session#pfl_after_queue?`: also one still queued in a scheduled block) ends the pre-listen with one line saying it already plays on MAIN; `launch` alone launches the one part on CUE (`Session#cued_names`: cue players playing or queued, and pre-listens; an error naming them when there are several, or saying none is); a name nothing answers to suggests cued, track, and scene names (`launch :pd`: did you mean :pad?).  A `:launch` landing after a later `bg`/`go`/`tweak` restarted the track (which stops its cue) lands as nothing instead of raising on the render thread (found by the session fuzz's cue/launch step, seeds 6 and 20; shrunk songs kept in `session_fuzz_spec.rb`).  `bg :pad` with only a track's name plays its clip again (a note when it already plays).  The 2-channel `:split` stays as it was (the maintainer expected the left/right split; 2026-10-28).

## Routing

- A player's strip (contract K7) is fade, level (arrangement.md "Track levels"; a cue player plays at its track's level), mute/solo, then the **route**: two gains, MAIN and CUE (`Session::Cue::Levels`, exact `Fades::Ramp`s counted in session frames).  Players with neither (every player unless cued) take the old path unchanged (`Player#cue` nil).
- `cue` starts right away unless given a launch point (`on:`/`in:`/`at:`): clips follow the timeline, so the part is in time anyway, and a `bg`-style next-bar default would leave a `cue` then `launch` in the same bar never heard (found by `cue_spec`).
- Cue players are named `:"name/cue"` (like armed monitors' `:"name/live"`): MAIN 0, CUE 1.  So a cued replacement for a playing `:bass` runs next to it, and listings show both.  `mute :bass` mutes `:"bass/cue"` too; solos don't silence cue players (a solo is about MAIN).
- MAIN 0 also zeroes everything the player sends: buses, `to:`, readers.  So renders, stems, `rec_audio`, taps, and the UI's mix ignore CUE (cue players add exactly nothing to MAIN).
- CUE is **dry**: the cue mix is the cue players' (and PFL players') post-strip sound, before buses and the master chain (the study's open question 4; dry by default, no doubled master cost).
- **Phones mix** per span: `phones = (cue * (1 - cue_mix) + main * cue_mix) * phones`, where `main` is the post-master MAIN mix (with a post-chain master gain).  `cue_mix` starts at `Session.cue_mix_default`: 0 (CUE only) unless the user saved another with `cue_mix 0.3, save: true` (maintainer 2026-10-18: "Default cue only, saveable as a user preference similar to monitor level"; `Cue::Prefs`, `cue.json` in `Internal.help_data_dir` next to the listening level, applied by bin/sound.rb at startup like `Help::Level.apply`, so scripts and specs start from 0).  `phones` starts at 1 (0 dB, range 0..2).  Both are Session knobs created on the first cue command (`Cue#cue_knobs`), so `turn`, `over:`, `learn`, takes, undo, and the knob panes work on them; a user knob of that name is used as it is.
- The monitor trim (`MonitorTrim`) applies to the phones channels too.

## Launch

`launch :x` is one change (`:launch`, subject `:x`) at the launch point: the track's `q:` (else the set's `quant`) for tracks, `:bar` while playing otherwise, or `on:`/`in:`/`at:`.  On its exact landing frame:
1. the players named `:x` on MAIN stop there, crossfading out over `fade:` (default the 5 ms declick);
2. `:"x/cue"` is renamed `:x` (the same Player and graph: envelopes, delays, clips carry on);
3. its MAIN gain ramps 0 -> 1 and its CUE gain 1 -> 0 over the same `fade:` (CUE stays at 1 if `:x` is pre-listened).
Scenes (`Arrangement::Cue#cue_scene`, `#launch_cued_scene`): `cue :drop` cues each patch track the scene gives a new clip; `launch :drop` launches those cues at each track's launch point (`tr.q`, else the scene's `q:`, else `quant`), adopting their clips, then runs `go :drop`, which leaves them alone (already playing that clip) and changes the rest.

For tracks the Arrangement adopts the cued clip as the track's clip (`Arrangement::Cue#adopt_cue`), so scenes and listings know what the track plays.  `launch` with nothing cued raises (live: `live_error`).

PFL: `cue :x` on a playing player ramps its CUE gain to 1 (declick), MAIN unchanged; `uncue :x` back to 0.  A graph replacing `:x` keeps the PFL (it belongs to the name, like mutes).

## Undo, takes, exactness

- `cue :x, sound` is a `:bg` of `:"x/cue"` and `uncue` a `:stop` of it (the usual player undo).  PFL and launch are `:cue`/`:uncue`/`:launch` changes with subject `Cue::CueSubject`; their snapshot (`Cue::CueState`) holds the PFL set, the cue player's serial, and the `:x` PlayerState, and undoing a launch renames the player back to `:"x/cue"` (CUE again) and restores the old `:x` the usual way.
- Every gain change is a frame-counted ramp from the change's landing frame, so CUE and MAIN are the same at any buffer size (`cue_spec` renders at 800, 128, and 7 frames); takes replay the console lines and land them on the recorded frames.

## Outputs

`Session#cue_output` (console `cue_output`):
- `:auto` (default): `:ports` when the output has twice the Session's channels (MAIN 1-2, CUE 3-4); on a stereo Session with a 2-channel output, `:split` from the exact frame CUE is first used (a cue player starting or a PFL landing; MAIN stays stereo until then), else `:off`.  Maintainer 2026-10-18: "Split with a first time warning; clubs are usually mono anyway": the first `cue` in the console on a 2-channel output warns once per user (saved in `cue.json`) and names `cue_output :phones` and `:off`.
- `:ports`: CUE on channels 3-4.  Open such an output with `CUE_OUTPUT=ports bin/sound.rb` (the Session then opens `MB::Sound.output(channels: 4, cue: 2)`) or, while idle, `use_output output(channels: 4, cue: 2)`.  On JACK the ports are `out_1`, `out_2`, `cue_1`, `cue_2` on the one shared client, connected to physical playback 1-4 when they exist (else the cue ports stay unconnected for qjackctl/qpwgraph); miniaudio opens a 4-channel device (an interface with 4 outs; a stereo device would downmix).  One device or client keeps both sample-locked (two devices would drift; ASRC is a later project).
- `:split` (2-channel; the `:auto` default there once CUE is used): left = MAIN in mono, right = the phones mix in mono (the DJ "split cue" for a laptop and a Y-cable).
- `:phones` (opt-in, 2-channel): both channels carry the phones mix (practicing on headphones alone; turn `:cue_mix` up to hear MAIN).
- `:off`: CUE isn't heard, MAIN stays stereo (in the console the first `cue` on an output that can't carry CUE warns and names the options).
Renders never write CUE.

## Decided (maintainer, 2026-10-18)

Names as built; `cue_mix` default 0, saveable; `:split` by default on 2 channels with a once-per-user notice; `go`/`bg` end the cue; scenes cueable; CUE stays dry (no copy of the master chain); `arm` monitors stay on MAIN.

## Later

- CUE as a stem in renders (`render(..., cue: 'phones.flac')`).
- Cueing an armed track (its monitor on CUE while playing in).
- Terminal UI: a CUE badge from `Session#cue_info`, CUE meters from the phones channels, Tab for the CUE/MAIN prompt target, `^L` launching the last cue (Linux UI work).
