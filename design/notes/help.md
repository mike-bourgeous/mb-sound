# Console help

Console help for `bin/sound.rb` (branch help-1, 2026-10-13), built on the research spike `research-help` (commit 45dedbc8, `research/help/README.md`: inventory, four designs, captures).  CLAUDE.md keeps a summary and points here.  Update both when behavior changes.

## The maintainer's decisions (2026-10-13)

1. Take over the `help` name; Pry's help moves to `pry-help` (as `play`/`reset`/`hist` already are).
2. Welcome screen: "A few more lines but yes": a short welcome plus one random runnable `help.tip`.
3. Guard spec: a new public console command with no help topic entry or module exemption fails CI (plumbing modules exempted as a whole with a reason).
4. Lessons: "Start light but then a full vimtutor-like tutorial is warranted": phase 1 is the light framework (`:set`, `:knobs`, `:flow`, `:record`); the tutorial is designed in `help_tutorial.md`.
5. "Try it" levels: "Pro vs. consumer gain levels are tough; consumer expects near 0 for audibility probably.  Maybe start with a level test at -30 and a 'press up or down until level is good'": the level check below.  Round 2: "Ok to peak to -3 if the user chooses it"; the level becomes a monitor trim for live playback ("makes sense then to set a monitor gain"); on the very first launch the check runs "Before starting Pry even".
6. `now`: a one-shot printout now; a live panel later with the terminal UI.
7. The did_you_mean workaround in bin/sound.rb's exception handler stays until an mb-util upstreaming round.

## Layout

`lib/mb/sound/help.rb` loads `lib/mb/sound/help/`; it is not part of `require 'mb/sound'`, but `MB::Sound::HelpAutoload` loads it on the first `help`, `now`, or `lesson` in any script (fixes-5, 2026-10-13: a plain script got a NameError).  bin/sound.rb requires it, prints `Help.welcome`, and calls `Help.install_pry!` (renames Pry's help, wraps Pry's printer so pages print as text, adds the lesson `after_eval` hook).  `MB::Sound` extends `HelpMethods` (`help`, `now`, `lesson`).

| file | what |
|---|---|
| `help.rb` | loader, `Help.data_dir`, `Help.page_for` (what `help x` returns for nil, Symbol/String, Regexp, Method, graph), `PagePrinter`, `install_pry!` |
| `help/help_methods.rb` | the console commands |
| `help/doc_index.rb` | console commands (the `*Methods` modules MB::Sound extends), the recorded DSL surface, Numeric mixins, Pry commands; doc comments via `method_source` |
| `help/topic.rb` | `Topic` and its builder (`about`, `commands`, `dsl`, `note`, `see`, `example`) |
| `help/pages.rb` | `Desk` (what `help` returns), `Tip`, `LevelPage`, `TopicList`, `TopicPage`, `MethodPage`, `SearchPage` (sq80-lib-1, 2026-10-17: lists matching topics (name, title, about) before methods, so `help /sq80/` finds `help :sq80`; topic text keeps code spans unbroken when wrapping) |
| `help/sheet.rb` | the one-screen sheet; lines are never-run blocks shown with Prism |
| `help/try.rb` | `Try.run` |
| `help/level.rb` | the listening level and the level check (sets the monitor trim, `session/monitor_trim.rb`) |
| `help/now.rb`, `help/graph_page.rb` | `now`, `help node` |
| `help/lessons.rb` | lessons, progress, the runner |
| `help/coverage.rb` | the coverage guard's exemptions |
| `help/welcome.rb` | the welcome screen |
| `help/content/` | the hand-written part, all Ruby: `topics.rb` (23 topics), `sheet.rb`, `lessons.rb` |

Pages are values whose `inspect` is their text (`t = help :knobs; t.try`).  Text is generated: each name's line is the first sentence of its doc comment, aliases and signatures come from the code (`Method#parameters`, `original_name`), and module comments' `Example (bin/sound.rb):` blocks are the model for console examples.  Only the choice of names, the blurbs, the sheet lines, the examples, and lesson prose are hand-written.

Topic names are singleton methods of the Desk (`help.knobs`), so a typo is a NoMethodError with a did_you_mean suggestion (shown by the console's handler).

## Try it, the listening level, and the monitor trim

`help(:knobs).try(n)` prints the example's source (Prism, from the block), runs the block in MB::Sound as if typed, and schedules a stop (0.25-bar fade) for the players it started after its bars.  Examples name their players `try`, `try2`, and their tracks/knobs/scenes `try_*`, so a try never replaces your players.  Constants (`A1`) resolve lexically in `module MB::Sound`, where the content files are written.

Round 2 (maintainer, 2026-10-13: "Didn't realize master gain was pre-effect; makes sense then to set a monitor gain"): the saved level is a **monitor trim** (`Session::MonitorTrim`, `lib/mb/sound/session/monitor_trim.rb`; console `monitor_gain`, alias `monitor`), not a gain on examples.  Round 1's `Try::Context` (which scaled what examples played) is gone.
- One process-wide linear gain (`Session.monitor_gain`, 0 to +27 dB), applied in `Session#process_buffer` to the buffer written to the output only: after the master chain (and any limiter in it) and the master gain.  The returned mix, taps (vis), `rec_audio` files, stems, and renders never see it; `render` uses non-realtime Sessions, which don't monitor (`Session.new(monitor:)`, default = `realtime`).  Foreground `play` plays through the background Session (play-1, 2026-10-17), so it gets the trim like everything live.
- So every live sound (try, lessons, hand-typed code) plays at the listening level, and nothing saved changes.  `monitor_gain` lines are in `Take::FOREGROUND` (replays skip them).
- Peaks the trim pushes over full scale are clipped to -1..1 on the way out, with a warning at most every 10 s (`Monitor trim +27.0 dB clipped a peak 7.0 dB over full scale ...`) and a per-Session count (`monitor_clips`).
- Cost: 0.09 us per 800-sample stereo buffer at 0 dB (a comparison), 8.7 us with a trim, 10.0 us when it also clips (0.06% of the buffer's 16.7 ms; measured 2026-10-13).
- Note: in the code, `master_gain` is applied after the master chain too (`process_buffer`), so it is post-limiter as well; the difference is that it reaches renders, recordings, and stems.

The level check (`help.level`; bin/sound.rb runs it before the first Pry prompt on the very first launch, when stdin is a terminal and the output type is `:device`; not with OUTPUT_TYPE=null/ffmpeg, a piped stdin, scripts, or `MB_SOUND_LEVEL_CHECK=0`; Enter keeps the default right away; an output error skips it with a note): a soft A3 triangle swelling once a second (`Level.signal`, peak exactly 1) plays at `REFERENCE_DB` = -30 dBFS peak before the trim through `Level::SessionPlayer` (a player named `:help_level` added with `Session#add`, gain divided by the master gain), and the keys move the monitor trim, so the output peak is the shown level; `stop` restores the trim it found, and Enter saves the level and sets the trim from it.  Keys: up/down (or `+`/`-`, `k`/`j`) 3 dB, left/right (`l`/`h`) 1 dB, `r` back to -30, Enter/space/`y` keeps, `q`/Escape/Ctrl-C/end of input cancels.  `RANGE` is -60..-3 dBFS (maintainer: "Ok to peak to -3 if the user chooses it (-9 to -6 RMS maybe?)"; the tone's RMS is about 6 dB under its peak).  `help.level -20.db` sets it directly (a bare negative number is read as dB with a warning, live mode); `help.level` without a terminal shows it.  Saved as `level.json` in `Help.data_dir`; bin/sound.rb applies it at startup (`Level.apply`), and the welcome shows the trim.

`Calibration.new(input:, out:, player:, start_db:)` takes any input with `getch`/`getc` (StringIO in specs), any output, and any player with `start(db)`, `level=`, `stop`, so the key loop and the level math are tested without a terminal or a sound card.  The real terminal path uses `IO#getch` (io/console raw mode per key) and reads arrow keys' escape sequences whole (`wait_readable(0.05)` tells a lone Escape from an arrow).

Example levels (the guard spec), relative to the tone so they scale with the chosen level: every sound example, played for its bars plus one in a non-realtime Session at the default master gain, must peak at most `EXAMPLE_PEAK_OVER_TONE_DB` = 9 dB over the tone (-21 dBFS at the reference) and have integrated loudness within `EXAMPLE_LOUDNESS_WINDOW` = 7 LU of the tone's (-34.9 LUFS at the reference).  At a chosen level L, examples peak at most at L + 9: under full scale up to L = -9 dBFS; above that, transient peaks (drums, plucks) can reach the trim's clip, which warns.  A single tone at about -20 dB before the master bus lands near the tone; saws, filtered parts, and drums need -8 to -16 dB.  Measured 2026-10-13 (19 sound examples): peaks -21.7 to -31.6 dBFS (at most 8.3 dB over the tone), loudness -30.7 to -39.7 LUFS.

## now

`now` (one-shot, under 1 ms) reads public Session state: bar:beat and tempo, the flow position, players with track/mute/solo flags, knobs as bars with ramp targets, scenes with the current one marked, queued and recent journal entries, then "you can": commands filled in with your own names (stop/mute the last player, turn the first knob, `go` the scene after the current one, form controls, `undo`, `take.save`).  The live panel waits for the terminal UI.

## Lessons

A lesson (`Help.lesson :name, title, minutes:`) is steps with `say` (prose), `type { code }` (shown, never run by the hook), `check('description') { |memo| ... }`, an optional `start { ... }` whose result goes to the check (for "something new since the step began": the capture step looks for a `:capture` change queued since, since `captures.length` also grew when an earlier `rec` closed), and `hint`.  `needs :midi` marks lessons that need a keyboard (the spec plays a stand-in); `needs :idle_set` (`:set`, `:flow`) makes `lesson` refuse (`live_error`) to start over a playing form or a scene whose tracks play (`Lesson#busy`), and every lesson name (tracks, scenes, sections, knobs) starts with `l_` (fixes-5: `lesson :flow` had redefined a playing song's `:intro`/`:outro`).  Files a lesson's code makes without a path (`rec_audio`) go to `Help.data_dir/lessons/<name>` (`LessonRunner#files_dir`), never the take directory.  `lesson` lists the lessons once the active one is done.  The Pry `after_eval` hook runs the current step's check after every console line; passing prints a check mark and the next step.  `lesson.run` types the step for you, `next`, `back`, `hint`, `quit`; progress is saved in `Help.data_dir/progress.json` (`lesson :set` resumes, `restart: true` from the top).

Lessons in phase 1: `:set` (6 steps), `:knobs` (5), `:flow` (4), `:record` (5: arm, `rec 2`, `capture :l_keys, 1`, `rec_audio`, wrap up).  Their names start with `l_`.

## The guard spec (`spec/lib/mb/sound/help_spec.rb`, ~10 s)

- Every topic name is a real method; every console command a topic lists is a console command; every method a sheet line calls exists (placeholders `g b l r bass2 beat` and section names allowed).
- Every example plays in level bounds (above); non-sound examples (`sound: false`: plots, Ruby) run without errors.
- Every lesson step's check fails before its code and passes after, in order, in one Session; the result stays within the peak bound.
- Coverage (`Help::Coverage`): every public console command (not aliases or setters; a listed alias covers its method) is in a topic, on the sheet, or exempt: whole modules in `EXEMPT_MODULES` (FFT, gain, window processing, script helpers, live-mode switches) or names in `EXEMPT`, each with a reason.  A new command fails the spec until it has a topic or a reason.
- The level key loop, the level as monitor trim (the tone peaks at the shown level in a monitored Session; cancel restores the trim), the first-launch check and its skips, pages, `now` mid-set, the welcome, the Pry setup; `spec/bin/sound_spec.rb` pipes `help :knobs`, `now`, and `help.knobz` through a real bin/sound.rb.

Specs set `MB_SOUND_HELP_DIR` to a temp dir (and stub `Take.data_dir`/`#home` for `rec_audio`), so nothing is written to the user data dir, and restore the process-wide monitor trim after each example.  `spec/lib/mb/sound/session/monitor_trim_spec.rb`: the trim reaches only the output (not the returned mix, taps, or recordings), applies after a limiter (-6 dBFS ceiling + 3 dB trim = -3 dBFS out), clips with one warning, leaves renders bit-identical, and reaches foreground play only on the live output.

## Takes

`help`, `now`, `lesson`, and `monitor_gain`/`monitor` lines are in `Take::FOREGROUND`, so replays skip them (including the sound a `try` or `lesson.run` made).

## Later

- The full tutorial (`help_tutorial.md`).
- `now` as a live panel with the terminal UI (knob bars that move, per-player level sparklines, the flow timeline).
- A doc pass: example lines for console commands without one (the spike counted 122 of 189), following Pitch/Notes delegation to documented methods in method pages.
- did_you_mean in mb-util's `color_trace`, then drop the handler workaround.
