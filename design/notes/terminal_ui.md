# Terminal UI

The live terminal UI for the console (`bin/sound.rb`).  Step 1 (ui-2, 2026-10-15) made plots fast enough for live panes (`fast_ui`, `Plot::Live`; see plotting.md).  Step 2 (ui-3) is the read-only **dashboard band**: a few rows above (or below) Pry, kept out of scrolling with a scroll region, drawn by an in-process painter from per-buffer snapshots.  Step 3 (ui-5, the section "The tiled screen" below) is **`ui :tiles`**: the whole screen owned cell by cell, panes tiled in a split tree around the real Pry/Reline, which runs on an in-process pty and draws into its pane through a terminal model.  CUE and the Deck's other parts wait for later steps.

Background: research-ui-2 d3e30356 (never merged): `research/terminal-ui-2/README.md` (painter measurements on the Linux desktop) and `ARCHITECTURE.md` (layers, three options).  Decisions accepted by the maintainer (2026-10-15): option 1 (in-process painter, native cell grid, "snapshots in, cells out", per-pane rates, `Thread.pass` between panes, never poll `Session#players` per frame); a DECSTBM band first, Pry unchanged; live panes default to quadrants in 256 colors (iTerm2 is throughput-bound at ~2.5 MB/s, so bytes per frame matter; Braille stays available per pane); names `ui` / `ui :deck` / `ui off`, `pane :name do |c, s| ... end`, `layout :name do ... end`, `ui.save`.

## Using it

```ruby
ui                      # the default band: transport, form, tracks, queued, master meters, scope (7 rows)
ui :deck                # 13 rows: adds knobs and CPU per part
ui :mini                # one line: transport and form
ui :band, at: :top      # above the scrolling text (default :bottom since ux-1; also color: :truecolor, look: :scope for Braille)
ui :wall                # every pane (200x60 and up); ui :tiles, :studio, :keys
keys                    # the keyboard (F2 in the tiles); fg after Ctrl-Z; jobs
ui.fps; ui.target_fps = 30; ui.frame_rate   # measured vs the painter's rate (NAV f shows it)
UI.messages.recent      # warnings while a screen was up (NAV m: the messages pane)
ui off                  # (`off` is :off; also ui :off, ui false)
ui.stats                # painter CPU per refresh, bytes per frame, the slowest refreshes

pane :where, height: 1 do |c, s|          # s: a Snapshot, c: the pane's Canvas
  c.puts ['bar ', :dim], [s.stamp, :key], '  ', [s.form&.section.to_s, :name]
end
layout :mine do
  cols { pane :transport; pane :where }
  cols { pane :meters; pane :scope, width: 50 }
end
ui :mine
ui.save                 # ~/.local/share/mb-sound/ui/mine.rb (Mac: Application Support), loaded by `ui :mine` later
```

The prompt shows Pry's line counter and only state that commands change (ux-1, maintainer 2026-10-17: a prompt is drawn once, so a playback position read as a line number): recording and armed tracks and the form's section or scene, `sound.rb [12] ●rec:lead arm:pad drop MB::Sound(0) >` (`UI::Prompt.main`, `UI.prompt_status`; `UI.prompt_status_enabled = false` turns the state off).  Lines inside unclosed constructs get a dim prompt as wide as the main one naming what is open (`do ( … >`; `UI::Prompt.continuation`, from Ripper tokens, set as Reline's `prompt_proc`).  Enter runs a complete buffer wherever the cursor is (`UI::EnterSubmits`, prepended to `Reline::LineEditor`); an incomplete buffer gets a new line, and Alt-Enter always does (not Ctrl-J: type-ahead reaches Reline as "\n" through the tty's ICRNL).  Tab completes track, scene, knob, bus, layout, and pane names after the commands that take them (`go :<Tab>`, `turn :c<Tab>`, `ui :<Tab>`), and lists session names first for any other Symbol.  `now` suggests `ui`; `help :ui` is the topic.

## How it works

```
 render thread (Session#process_buffer)
   inside the render lock, when the painter took the last snapshot:  feed.capture(session) -> Session#ui_parts
   after the output write:                                           feed.publish(mix, load) -> meters, scope ring, Snapshot
                                                                        (one frozen object, one reference swap)
 painter thread ('MB::Sound::UI', priority -1, up to 60/s)
   take the newest Snapshot; Poll (4/s) for Slow data; size check
   each due pane: draw into its Canvas (or Plot::Live bytes); Thread.pass
   Grid#frame (changed cells, C) + scope bytes -> one write:
     CSI ?2026h  ESC 7  [CSI top;bottom r]  cells  ESC 8  CSI ?2026l
```

- **Snapshots in** (`UI::Feed`, `lib/mb/sound/ui/snapshot.rb`): the render thread publishes a frozen `UI::Snapshot` only after the painter took the previous one (so at most once per buffer and at most at the painter's rate), with what accumulated since: render load mean/max, each part's CPU share (`PartLoad`: players by state, buses, the master chain; graph times counted in `Player#cpu`/`Chain#cpu` only while a feed is attached), master meters (`MasterMeter`: sample peak and RMS per channel, Annex 2 true peak through `FastLoudness.true_peak`, short-term LUFS from K-weighted 100 ms blocks over 3 s), the latest 1024 samples per channel (`ScopeRing`), output underruns, and knob values.  Meters and the scope run only when a visible pane `needs` them.  Peaks between frames are never missed.
- **Slow data** (`UI::Poll`, painter thread, 4/s): tracks, scenes, armed tracks, the form (`Form::Playback#upcoming`), knob specs, and queued changes and running recordings, which it keeps from the journal's new entries (`Journal#subscribe`) instead of rereading `Journal#changes` (it grows with the session).  Nothing it calls takes the render lock (`Session#players`, `#clock`, `#strip_info` do; a spec checks).
- **Cells out** (`UI::Canvas`, `UI::Pane`, `UI::Panes`): panes draw text segments with color roles (`UI::Theme`), eighth-block meters with zones and a peak hold, and sparklines into their rectangle of a `Plot::Text::NativeCells` grid (`FastUI::Grid`; the Ruby mirror `Plot::Text::Cells` with `native: false` gives the same text and bytes, checked by specs).  The scope pane is a `Plot::Live` (look `:quad` by default) writing its own changed cells.  A pane that raises shows its error in its rectangle (warned once) and the others keep drawing.
- **Layouts** (`UI::Layout`): rows of `cols`/`rows`/`pane` with fixed `height:`/`width:` or `weight:` (default: the pane's natural width), one blank column between panes; `to_ruby` prints them back; `UI::LayoutLoader` reads saved layouts by walking the Prism tree (only `layout`, `pane`, `rows`, `cols`, literal arguments; never eval).
- **The band** (`UI::Band`): on start it scrolls the screen up by the band's height (so nothing is overwritten), sets the region, and puts the cursor back on its line.  SIGWINCH (chained with Reline's handler) and a size check every 0.5 s relayout and redraw; every 2 s the region is reissued with a full redraw (after `reset`, a pager, `clear`).  `UI::RelineGuard` (prepended to `Reline::ANSI` while a band is on) makes Reline see the region as the screen: cursor rows shifted below a top band, the height minus the band, and Ctrl-L clearing and redrawing the band.  Stopping resets the region and clears the band's rows.
- **Warm-up** (`UI.warm_up`, once per process with YJIT, ~0.4 s): the first frames otherwise hold the GVL for 10-30 ms while YJIT compiles the painter; `bin/sound.rb` runs it at startup, `UI.show` before the first band otherwise.
- `UI::Screen` is a small VT replayer (CUP, DECSC/DECRC, DECSTBM, erases, SGR) for specs (diffed frames must rebuild a full redraw) and captures.

## Measurements (Mac container, i9-9880H, 2026-10-15)

`bin/ui_demo.rb` plays "Last Stop" with the band drawn to /dev/null at 30x120 (no terminal in the container), 800-frame NullOutput buffers, YJIT, after `UI.warm_up`; GVL waits from `FastUI::GVLProbe` (Ruby's internal thread event hook).

| | render-thread wake delay p50 / p99 / p99.9 / max (ms) | waits > 2 ms per minute |
|---|---|---|
| band off | 0.000 / 0.001 / 0.03 / 0.03-0.8 | 0 |
| band on (`:band`, 60 fps) | 0.000 / 0.21-0.28 / 2.2-4.5 / ~10 | 6-10 |

Painter per refresh (band layout, 120 columns, ansi256): CPU p50 0.2 ms, p99 0.9 ms; refreshes that drew a pane p50 0.3 ms, p99 1.1-1.5 ms; 1.8 panes per refresh; ~400 bytes per written frame (max ~2.5 KB on the 2 s full redraws); ~200 Ruby objects per refresh (scope ~220 per draw, meters ~105).  The waits over 1 ms are attributed by `GVLProbe.blockers` to the painter (a few: its first full frame, ~30 ms including the scope's first Plot layout, and the poll's occasional 2-3 ms) and to "none of the watched threads" (GC pauses and GVL handoffs); a GC run takes ~10 ms here.  Render load is unchanged (p50 7-9%).

The timing spec (`spec/lib/mb/sound/ui/painter_timing_spec.rb`, no YJIT, 256-frame paced buffers, the deck at 60/s, 40x160): render wait p99 0.18-0.29 ms (max 0.3-0.4 ms), painter busy p99 ~1 ms; budgets 2 ms and 4 ms times the machine's slowdown (a full deck redraw timed in the same process over 1.1 ms).

Not measured here: a real terminal's own parse and draw time (iTerm2, Konsole), native macOS, JACK at 128 frames, underruns on a sound card (the container's NullOutput has no underrun count).  `bin/ui_demo.rb [-L low] [--compare]` measures them in a real terminal.

## The tiled screen (ui-5, 2026-10-15)

Design spike: research-ui-4 0ff717a7 (`research/terminal-ui-4/`: README, ARCHITECTURE.md, COMPARISON.md, the prototype).  Maintainer's decisions (2026-10-15): REPL option (a2), real Pry/Reline on an in-process pty, rendered by our VT model ("(b) only if probe wins": DECSLRM margins not built); the REPL pane has its own scrollback (10k lines, `/` search, OSC 52 copy) while the band keeps the terminal's; Ctrl-] (0x1D) is the NAV key, immediate, and a lone Esc enters NAV only when `ui.nav_esc = 0.3` (seconds; 0.25-0.4 sensible) is set, an Esc followed by a key within that time going to Reline; pane files, layouts, and themes are all data loaded by a Prism walker; interactive resizes save weights as cells/gcd; one Action stream for keys, the `:` palette (Ruby one-liners in the console binding), and MIDI (`ui.on C1, :zoom`); glyphs picked by measuring ambiguous width; a gem-boundary guard spec.

```ruby
ui :tiles                 # transport/form row; the REPL beside tracks, queue, meters, scope
ui :studio                # tracks | REPL over a scope | tabs of meters, knobs, cpu
layout :mine, focus: :repl do
  cols height: 1 do pane :transport; pane :form end
  cols do
    repl weight: 2
    rows(width: 40) { pane :meters, height: 6; pane :scope, look: :scope, rate: 30 }
    tabs :knobs, :cpu
  end
end
ui :mine
ui.split :v; ui.show :knobs; ui.resize :right, 4; ui.undo; ui.zoom; ui.save :mine
ui.on C1, :zoom; ui.on_cc 21, :tab; ui.on(C2) { go :drop }
ui.theme :mono; ui.nav_esc 0.3; ui.mouse
```

**Keys.**  REPL mode: everything goes to Reline (Ctrl-C is SIGINT, as a terminal's line discipline would send; Ctrl-Z hides the tiles, see below).  Ctrl-] toggles NAV: 1-9 (the badges), Tab/Shift-Tab, hjkl focus; z zoom; s/v split below/beside (the new slot shows how to `show` a pane); x close; = equalize; arrows resize by 1, Shift-arrows by 5; u / Ctrl-R undo/redo (100 steps; focus isn't a step); [ ] tabs; PgUp/PgDn/Ctrl-B/Ctrl-F/g/G scroll the REPL's scrollback; / search (smart case, backward; n/N again); y copy (the match's line, else the visible text) with OSC 52; : palette; Ctrl-L redraw; i, Esc, Enter, Ctrl-] back.  The status line shows the mode, the focused pane, hints or the last message, and bar:beat.

**Input as a state machine (ux-1 round 3, 2026-10-17).**  `UI::Input::Router` declares its states (`STATES`: :repl, :play (a screen without a console), :nav, :line, :grab, :overlay, :pending), the event classes it tells apart (`EVENTS`: nav_key, keys_key, interrupt, suspend, prefix, global, key, release, paste, tick, other), and a `TABLE` row (handler, what it does) for every pair; `Router.table` prints it; `router_spec.rb` checks every pair has a row and a handler, Ctrl-] from every state lands in NAV and a second press returns, overlay + key == NAV + key for every NAV binding, and random walks keep the invariants.  Ctrl-C, Ctrl-Z, F2, releases, and the overlay go through the table (one owner for input; Tiles#handle only relays while hidden).  Prefix chords (`Router::Prefix`): Ctrl-W (vim's window keys: h/j/k/l and arrows, w/Ctrl-W, W, p last, s, v, o zoom, c close, =; a key it doesn't bind passes through to the REPL after Ctrl-W, so word delete still works; `window_prefix: false` off) and the held lone Esc (`nav_esc`) share one mechanism.  Ctrl-] always enters NAV, from KEYS and prompt lines too (a line is kept), and Ctrl-] in NAV goes back; i/Enter/Esc in NAV: the REPL.  Keys a state can't take are refused with the reason on the status line.  Focus follows the mode (REPL mode: the REPL; KEYS: the keyboard), pinned in one place (`Tiles#tile`).  Input handling and Ruby mode changes share one lock.

**The key table** (`UI::Keys`, pattern C): keymaps carry their help (`Keymap#on(..., help:, label:)`, `group`, `doc`, `help_groups`): Router::NAV and WINDOW, Keys::NAV_EXTRA, the REPL's direct keys (`REPL_DEFAULTS`: Alt-PgUp/PgDn scroll the REPL pane without NAV, typing back to live; skipped when the user's inputrc binds them, read by `Input::RelineKeys.user_bound?` in every byte form), `Keyboard::KEYMAP` (KEYS mode acts through it), step entry docs, script screens' `SONG_SCREEN`/`SYNTH_SCREEN` (Tiles `play_keys:` + `on_action:`; repeats act like presses; Esc quits a song screen, panics a synth screen), and `ELSEWHERE` (each REPL-side UI key in the band and without a UI).  The `?` overlay, `help :ui` (`Tiles::KEY_HELP`, `Tiles.key_table`), and `keys_spec.rb` read it.  `ui.bind ['k', :ctrl], :keys` / `ui.unbind` add users' keys (REPL or NAV; Ctrl-K as the keyboard toggle is such an option, maintainer 2026-10-17).  Panes declare keys of their own (`UI::PaneKeys`: `keys do on 'L', :cycle_look, help: ... end` + `key_<action>(state, *args)`), consulted first in NAV while focused and shown in the overlay.

**Outside the tiles** (`UI::ConsoleKeys`, Reline *default* bindings, so an inputrc wins): Ctrl-] opens the tiled screen in NAV (the band's counterpart: band/mini :tiles, deck :studio; hidden tiles come back) and F2 KEYS, the line being typed carrying on in the REPL pane; IDE editing keys Ctrl-Backspace (^H unless it is the tty's erase), Ctrl-Delete, Ctrl-Shift-Delete (`Input::RelineKeys.install_editing_keys`).  Never call Reline's own `Config#read`: Reline sets up its default bindings (bracketed paste, cursor keys) only when it reads the inputrc itself.  `ui` returns `UI::Facade`: the same surface in every mode (`ui.keys` from the band opens the tiles; the other screen's commands say what to do; `ui.mode`, `ui.screen`).

**Output owner.**  `Tiles#write` is the one writer of frames; a frame with a raw newline is dropped of it and warned about (specs fail).  Status flashes are one line (`Tiles.one_line`).  Palette lines of console Ruby print their output and value into the REPL pane (`ReplHost#print_above`).  Warnings: a new one opens the messages pane (NAV m: away); the REPL's own command's warnings print in the REPL (`UI.repl_thread?`).

**Key repeats** (`Keyboard::HoldTracker`, item 9): per-key states :idle/:pressed/:repeating with `TRANSITIONS`; gaps up to 90 ms are always repeats, a first repeat within 80 ms (40 ms once learned) of the delay is a repeat, and a strike followed by short-gap repeats teaches the delay retroactively (at most the first hold of a session retriggers once); `ui.keyboard.repeat_delay =` sets it.

**Ctrl-Z hides, the set plays on** (maintainer, 2026-10-15: "Hide screen, keep playing"; no process suspend in `:tiles`).  Ctrl-Z leaves the alternate screen for the plain console: the REPL's pty is relayed to the terminal's normal screen (its bytes written through unchanged, input bytes passed to the pty, Ctrl-C still SIGINT), so the same Pry and Reline keep going, the line being edited included (Reline redraws it after a forced SIGWINCH), and audio, the Session, and the UI's layout, edits, and REPL scrollback all stay.  Ctrl-Z again, `ui`, or `ui :<that layout>` brings the tiles back as they were; `ui off` or `exit` ends them.  No fd is reopened while hidden (reopening fd 0 while Reline waits on it blocks), and signal traps stay (Reline's WINCH handler for the line it reads wraps ours).

**How it works** (generic layers under `ui/screen`, `ui/input`, `ui/viewports`, `ui/themes`, `ui/data_file.rb`; `gem_boundary_spec.rb` keeps them free of MB::Sound outside UI, with an empty adapter list for now):

- `UI::Term`: alternate screen, raw input, bracketed paste, optional mouse/focus/kitty; `#leave` undoes all of it (twice-safe, at_exit, exceptions); a probe fenced by DA1 (DECRQM 2026, ambiguous width by a cursor report after one ambiguous glyph, kitty flags).  Tiles works on dups of the terminal's descriptors.
- `UI::Input::ReplHost`: in `:adopt` mode (the console) fds 0/1/2 are reopened onto the pty's slave, so the running Pry and Reline need no configuration, and `puts`, warnings, `live_error` text, and subprocess output (ffmpeg) land in the pane; `ui off` reopens them onto the terminal.  `:thread` mode runs its own Pry (specs, `bin/ui_demo.rb --tiles`).  A reader thread (priority -1) feeds Pry's output to the VT in 4 KB pieces with `Thread.pass` between and answers its queries (Reline's cursor reports).  Pane resizes set the pty's size and send SIGWINCH (Reline's own handler).
- `UI::VT`: rows as Strings (one character per cell, "\0" the right half of a wide character, widths from Reline's table with the probed ambiguous width), styles allocated only for styled rows, palette colors kept as indexes (fast_ui's `INDEXED` bit: SGR 31 stays 31, so the user's palette shows), scroll regions, the alternate screen, insert/delete, pending wraps; scrollback with stable absolute line numbers; draws only changed rows.
- `UI::Input::Decoder` and `Router`: bytes to Key (with its bytes, forwarded unchanged), Paste (one event), Mouse, Focus, Reply; modes :repl, :nav, :line (palette and search prompts with history).
- `UI::Viewports`: the prototype's immutable split tree (Pane/Split/Tabs Data, placement by fixed sizes then weights by largest remainder then mins), Tiler operations with undo, pane options per placement (`pane :scope, look: :scope, rate: 30`), `to_ruby`, and the loader.
- `UI::DataFile`: the one Prism walker for layouts, themes, and pane files: calls from a closed table per block level, literal values, constants from a closed table, LoadError with file:line and did_you_mean; replayed through the builders people use.
- `UI::Tiles` (mb-sound side): input thread, painter (ui-3's panes at their rates, the REPL from its VT only when it changed, gap rules with the focused pane's in the key color, NAV badges, status line; one diffed frame per refresh in DEC 2026 with the cursor placed in the REPL), the palette (a UI command like `show :knobs` runs on the screen with its arguments evaluated in the console binding; any other line is evaluated in the console binding, recorded before each line by `UI.install_pry!`), MIDI bindings read from `Session#midi_log` (no render lock), data-file reloads once a second.
- Data files (in `UI.layouts_dir`): layouts (`ui.save`; a file with a `repl` pane is tiled, else a band), `themes/*.rb` (`theme :mine, based_on: :default do role :title, '#9ef01a', bold: true; role :dim, 245; role :warn, :yellow; glyphs :ascii do play '>' end end`; built in :default, :paper, :phosphor, :mono), `panes/*.rb` (`pane :mix, kind: :meters, title: 'mix'`; kinds are Ruby: the built-in panes, :text, :knob, and `UI.pane_kind`).

**Measurements** (Mac container, i9-9880H, 2026-10-15, `bin/ui_demo.rb --tiles` with "Last Stop", 800-frame NullOutput buffers, YJIT, a pty standing in for the terminal; render-thread wake delay p50 / p99 / p99.9 / max in ms):

| | wake delay | painter CPU per refresh p50 / p99 (busy p99) | bytes per frame mean / max |
|---|---|---|---|
| no UI | 0.000 / 0.001 / 0.014 / 1.05 | | |
| :tiles 45x120 | 0.000 / 0.32 / 4.4 / 10.3 | 0.25 / 1.7 (2.0) ms | 372 / 8137 |
| :tiles 60x200 | 0.000 / 1.5 / 11.2 / 14.9 | 0.27 / 2.0 (3.7) ms | 403 / 15090 |
| :studio 45x120 | 0.000 / 0.28 / 6.8 / 10.9 | 0.26 / 1.4 (2.0) ms | 394 / 8960 |
| :tiles 45x120, 10 000 lines printed | 0.000 / 2.5-3.2 / 9-10 / 16-17 | 0.26 / 2.2 (3.9) ms | 434 / 8143 |
| :tiles 60x200, 10 000 lines printed | 0.000 / 1.6 / 9.2 / 10.5 | 0.29 / 2.8 (4.5) ms | 446 / 15096 |

REPL throughput: 10 000 lines of 75 characters in 0.44 s (~22 000 lines/s); the pty reader (VT) spent ~110 ms of CPU on them.  The first refresh takes ~30 ms (YJIT compiling, the scope's first layout).  Waits over 1 ms are mostly GC and unwatched threads (Pry's own thread printing): Pry printing the same 10 000 lines to a pty without a VT gives p99 0.13-0.2 ms, max ~4 ms in the same setup, so the VT adds about 2-4 ms of p99 while a flood lasts.  The spike's estimate holds: the Ruby VT is fast enough; a C VT is an option (question) if native terminals show glitches.

Specs: `spec/lib/mb/sound/ui/` (vt, decoder, viewports, tiles with a FakeTerminal: a pty read by a UI::VT, a real Pry/Reline; ui_files; gem_boundary), `spec/bin/sound_tiles_spec.rb` (bin/sound.rb in a pty: `ui :tiles`, puts/stderr in the pane, Ctrl-C, NAV, `ui off`, `exit` restoring the terminal), `spec/bin/ui_check_spec.rb`.

## The keyboard (ui-6, 2026-10-16)

Maintainer's request (2026-10-16): "a virtual keyboard panel for realtime note entry and clip creation that uses roughly the same key bindings as jack-keyboard or zynaddsubfx virtual keyboard when focused", then "Step editing also requested, maybe with one octave for notes and the number keys for duration?  Explore a couple of ideas and build one that makes sense".

```ruby
ui :keys                  # tiles with the keyboard below the REPL, starting in KEYS mode
ui.keys                   # (or NAV p) KEYS mode, the pane put in below the REPL if missing
ui.keys off: :tap         # note-off mode: :auto, :release, :hold, :tap, :legato
ui.keys step: true        # step entry
ui.keys patch: ->(v) { v.hz.square * v.amp_env }   # the default patch (nil: none)
ui.keyboard.clip          # the last clip made in step entry (.clips: all)
ui.keyboard.base = 60     # z is C4 (octaves; also - and +)
```

**Research** (sources in the ui-6 report): jack-keyboard binds X hardware keycodes in one QWERTY table: lower row z s x d c v g b h n j m , l . ; / (C to E), upper row q 2 w 3 e r 5 t 6 y 7 u i 9 o 0 p [ = ] an octave up and \ the A above ] (the G# key would be Backspace); z = 60 at its default octave 4; keypad +/- (and main -) octave, Shift high velocity (100) and Ctrl low (32) over normal 64, keypad * / program, PgUp/PgDn bank, Home/End channel, Space sustain, Esc panic.  ZynAddSubFX's VirKeyboard has the same QWERTY rows (\ and Enter continue its upper row chromatically), Dvorak/QWERTZ/AZERTY tables, separate octave counters per row (z = 48, q = 60 by default), velocity and randomness knobs, and no octave hotkeys; it works only while the widget has focus.  Terminals: the legacy encoding sends presses and OS autorepeats only, no releases; the kitty keyboard protocol's flag 2 reports press/repeat/release (`CSI code;mods:event u`), and text keys need flag 8 too (all keys as escape codes).  Flag 2 support: kitty, Ghostty, foot 1.11+, Alacritty 0.13+, WezTerm with `enable_kitty_keyboard = true`, Windows Terminal 1.25+, iTerm2 (its "Allow application to change how keys are reported" setting; version unverified), Konsole (merged 2026-05, release unverified); not VTE/GNOME Terminal, tmux (PR open), xterm.  Autorepeat defaults: X11 660 ms / 25 Hz, GNOME 500 ms / 30 ms; macOS is often cited as 375 ms / 90 ms (unverified).

**Keys** (play mode): the two rows (z = C3, q = C4, as ZynAddSubFX), - and + or Left/Right octave (the z key stays a C, C-1 to C6), Up/Down velocity (normal 96), Shift accent (127; shifted punctuation of a US layout counts), Ctrl soft (40; legacy terminals send it for letter keys only, and Ctrl-C, Ctrl-Z, and Ctrl-M (Enter) keep their meanings), Home/End channel, Space sustain (held while down with releases, else a toggle), Esc all notes off (CC 64 0, CC 123), Enter `capture` into the armed tracks, \` the note-off mode, Tab step entry, Ctrl-] back (also Ctrl-C: all off and back, never an interrupt).  Program and bank keys are left out (mb-sound synths don't read them).

**Note-off modes** (`UI::Keyboard`, shown in the pane): `:release` with kitty event types (chosen by :auto when the probe answered the kitty query, or once a release or repeat event arrives), else `:tap` (the default without key-up, maintainer 2026-10-16: fixed-length notes, `ui.keyboard.tap` seconds, 0.25 by default; repeats never retrigger); `:hold` (by backtick or `ui.keys off: :hold`) guesses held keys from autorepeats, `Keyboard::HoldTracker`: a key's second event sooner than 0.6 of the repeat delay is a new strike, later ones are repeats, the delay and interval are learned from what arrives (from 0.5 s and 35 ms), a note ends 2.5 intervals + 30 ms after its last repeat or, for a tap, the delay + 0.12 s after the press; keys pressed within 60 ms hold together as long as any of them repeats (the OS repeats only the last key), so chords sustain; `:legato` each note until the next (the new note-on first, so mono voices glide).  Every way out sends note-offs: Ctrl-], Ctrl-C, Ctrl-Z, terminal focus loss (?1004 is on in KEYS mode), `ui off`, exit; the spec checks each.

**The path into the Session** (`Keyboard::Link`): a `MIDI::VirtualInput` (a MIDI::Input stand-in: `#send_bytes`/`#note_on` from any thread, `#read_raw` as RtMidi deltas) read by a `LiveSource` (its :exact timing, or MIDI_TIMING=asap) and added to the current Session's default MIDI input with `MidiInput#add_source` (new: extra streams merged into each span in frame order, the input's own first; drained and dropped while a take replays).  So typed notes are stamped on frames beside a hardware keyboard's and reach armed monitors, `rec`, `capture`, the console's `midi`, the MIDI log, and takes.  With nothing armed, entering KEYS mode starts a default patch on the input (player `:"keyboard/live"`, a soft filtered saw, 8 voices); it rings out on the first note after a track is armed.

**Latency** (Mac container, i9-9880H, 2026-10-16; `bin` not needed: a pty, `ui :tiles`, a realtime Session on paced NullOutput, keys typed 130-180 ms apart, 42 per run; "frames" = the note-on's stamped frame minus the Session's render frame when the byte was written; "wall" = byte written to the note-on stamped in a span):

| buffer | timing | frames p50 / p90 / max (ms) | wall p50 / max (ms) |
|---|---|---|---|
| 128 | exact | 3.7 / 5.0 / 5.9 | 6.7 / 8.1 |
| 512 | exact | 10.7 / 15.1 / 19.1 | 21.4 / 44.2 |
| 800 | exact | 22.8 / 29.4 / 31.9 | 40.9 / 49.1 |
| 128 | asap | 0.0 / 2.7 / 2.7 | 4.5 / 5.7 |
| 512 | asap | 0.0 / 0.0 / 0.0 | 16.1 / 21.3 |

:exact keeps the spacing of the keys (one constant latency of about a read, plus the output queue on a sound card: LiveSource's L, ~18 ms with :low), :asap snaps each note to the next buffer.  The terminal, the decoder, and the router add well under a millisecond; the rest is the buffer.  Not measured: a sound card's queue, a real terminal's keyboard handling, ssh.

**Step entry** (`Keyboard::StepEntry`, Tab).  Designs considered: (a) one row of notes plus the number keys for lengths, with dotted/triplet toggles, rest and tie keys, and marks: the maintainer's suggestion and the closest fit to `seq` (each key is one step, lengths are Note length methods, marks are `.acc`/`.slide`); (b) a tracker grid (a cursor over rows of steps at a fixed step length, editing in place): good for drums and editing, but a second editor (cursor movement, insert/delete) and grid-shaped where `seq` is list-shaped (`grid` strings already cover drum rows); (c) jack-keyboard has no step mode, and Elektron-style step buttons (a fixed 16-step bar, notes per step, trigs with parameter locks) suit a pad grid more than a QWERTY row.  Built: (a).  Lower row notes (z..m , . / from the keyboard's C), 1-7 whole..64th, 8 dotted, 9 triplet (toggles), r rest, t tie, a accent and \` slide on the last step, Shift accents a note, notes within 80 ms (or, with releases, while a note key is down) join the last step as a chord (`C3.n4 & E3.n4`), Backspace undo, Delete clear, p plays the clip through the keyboard's output (tick-scheduled), w swaps the clip so far (`.loop`) into each armed track at its next launch point through `Arrangement#play` (the `bg :lead, clip` path: a swap if the track plays, else a launch; journaled and undoable) and keeps the steps for more edits (Shift-Enter does the same where the terminal sends it apart from Enter, i.e. with the kitty protocol; legacy terminals send CR for both, so w is the reliable key), Enter finishes.  The clip is built by calling the DSL (`MB::Sound.seq(...)` with Note constants, `Rest`, `Tie`, length methods, `.d`/`.t`, `.acc`, `.slide`, `&` for chords), the commonest plain length factored out (`seq(C3, D3, E3.n4).n8`), so its recipe prints it back (`to_ruby`; the spec evaluates the text and compares events).  Each entered note sounds for its length (0.08 to 1 s) through the same Link.  Enter keeps the clip in `ui.keyboard.clips` and puts its Ruby on the REPL's line (a bracketed paste, not run), back in REPL mode, so naming it is typing `riff = ` in front.

**Specs**: `keyboard_spec.rb` (rows and keys; each mode with a fake clock: release/repeat events, autorepeat hold, quick re-strikes, learned timing, chords, tap, legato, sustain, panic, all_off in every mode; step entry with the to_ruby round trip, chords by time and by held keys, preview, Enter; the pane's text), `tiles_keys_spec.rb` (a pty: `:keys` with kitty sequences, NAV p with legacy keys and every exit, step entry onto the REPL line, an armed track captured from typed keys through a realtime Session), `decoder_spec.rb` (event types), `midi_input_spec.rb` (merged sources, a VirtualInput's timing).

**Open**: the band (ui-3) can show the pane but has no input of its own (Reline owns stdin), so KEYS mode is tiles-only; a plain-console `keys` prompt is possible later.  Non-US layouts: legacy Shift detection maps a US layout's shifted punctuation; kitty's base keys are layout-independent for the letter rows only.  Program/bank keys, per-row octaves (ZynAddSubFX), and showing a hardware keyboard's notes on the strip are not built.

## The usability sweep (ux-1, 2026-10-17)

The maintainer's notes from testing natively in Konsole, item by item (brief: /app/tmp/briefs/ux-1.md).

- **Bugs**: pane bodies follow their canvas (stale panes after any relayout); leaving KEYS focuses the REPL (NAV i went back into KEYS, where Up/Down are velocity) and kitty-only key bytes reach Reline as legacy; `vis` and play's plot go to a scope/spectrum slot (`Tiles#plot_pane`, `Band#plot_pane`, `PlaybackMethods#visualize_in_ui`) instead of drawing over the screen; KEYS Enter's capture and step entry's swap run console lines through `UI.run_line` (journaled, undoable, take lines), one per armed track, a broken patch named in the messages pane with its line (`UI.error_origin`).
- **Prompt and line editing**: see "Using it" above (`UI::Prompt`, `UI::EnterSubmits`).
- **Tiles**: the band at the bottom by default; rules between stacked panes (box-drawing joins, `hrule` glyph, titles set into the rule, the focused pane's border in the key color); `?` in NAV shows the keys (`Tiles::KEY_HELP`, also on help :ui); warnings and live errors go to `UI.messages` while a screen is up (`:messages` pane, "! n (m)" on the status line, NAV m, a band strip, a summary on `ui off`; kept off the terminal when the screen owns it); `ui.fps` is measured (frames written per second), `ui.target_fps` the painter's rate, NAV f a readout, `ui.stats[:pane_cpu_ms]`; `ui :wall` for big terminals; the keyboard pane scales to a piano (2-5 columns per white key, velocity fill, neighbor octaves dimmed); `keys` and F2; `fg` and `jobs` after Ctrl-Z.
- **Scripts**: `--ui [LAYOUT]` plays songs (`:show`) and synths/effects (`:play`, KEYS mode) in a console-less screen (`Tiles` with `repl: :none`, `on_key:`; `Session#paused=` for Space); live synth/effect scripts take Esc (all notes off, twice all sound off), q, l, `MIDI_LOG=1`, `MIDI_STUCK=s` (`ScriptRunner::LiveKeys`).
- `debug_dump` writes the console's state to tmp/debug/<time>/.

- **Plots and tables**: `overlay a, b` / `overlay saw: a, square: b` (labels and titles inferred; `overlay_chart` for figures; the Hash-of-Hashes form is gone), and one themed table, `MB::Sound::Table`, for `table`, processing matrices, and the scripts (no `MB::U.table` left).

Round 2 (maintainer's answers, 2026-10-17): `sig.blend` (graph_nodes.md), the console's `capture` per armed track (arrangement.md); `:wall` stays opt-in, and a tiled screen starting on a 200x60+ terminal flashes a tip for it; Alt-Enter is the newline key; Space in `--ui` is a full pause.

Raw terminal writes while a screen is up: the adopted fds are the pty, frames go through `Tiles#write` (raw newlines dropped and warned); `IO.console`/`/dev/tty` writers (meter.rb's width read only) remain outside the guard.

## Patterns and lessons (ux-1, 2026-10-17)

The maintainer's request: for each bug, a mechanism that rules out its whole class, not only a regression test.

| lesson (bug) | mechanism | class ruled out | status |
|---|---|---|---|
| A pane body kept from an old placement drew at the old place after a relayout (bug 1) | Per-placement state is derived from the canvas it belongs to (`Pane#draw` remakes the body when the canvas changes); `tiles_property_spec.rb`: random splits, shows, closes, resizes, zooms, undo/redo, layout switches, and terminal resizes, then every cell pane must equal what a fresh screen with the same tree and size draws | any state surviving a relayout that changes what a pane shows | adopted (the property spec fails on the old Pane#draw for every seed tried) |
| Leaving KEYS left the keyboard focused, so NAV i went back into KEYS (bug 2) | Every mode change goes through `Tiles#mode_changed`; `Tiles#mode_problems` states the invariants (keyboard active, kitty flags, held notes follow the mode; nothing in KEYS while hidden; the REPL pane exists and is visible in REPL mode); a spec drives 40 random keys and Ruby calls (Ctrl-], p, i, Enter, digits, Ctrl-C both encodings, Ctrl-Z, notes, z, Esc, `ui.keys`, `ui.keys(false)`) checking them after each, then that the REPL still evaluates | mode/focus/terminal-state drift on any path into or out of a mode | adopted; it found three more: `ui.keys` from the hidden console entered KEYS while hidden, NAV x closed the REPL pane, and REPL mode with another pane zoomed over the REPL |
| KEYS Enter's capture and step entry's swap were missing from takes (coordinator, from ui-noise-1) | One command bus: UI actions run console commands through `UI.run_line(code, session)` (a take line when the console's take records that session); `command_bus_spec.rb` (Prism) fails when UI code calls a performance-changing method on a Session, Arrangement, or MB::Sound, with a reasoned ALLOWED list | UI changes that skip the journal, undo, or takes | adopted |
| `play`/`vis` drew over the band (bug 3) | The UI routes plots (`visualize` asks `UI.screen` and puts a scope/spectrum pane in) | plots over the screen | routed; a guard that fails on raw cursor-addressed writes to the real stdout from non-UI code while a screen is up (a spec-time `$stdout` wrapper) is proposed, not built |
| A closed `?` overlay sometimes stayed on screen (item 10): another thread asked for a full redraw while a frame painted, and the frame's end cleared the request | The painters take the redraw request at the start of a frame (`full = @full; @full = false`), so a request made during a frame survives to the next | lost redraws from any thread (mode changes, overlays, layouts, themes) | adopted (tiles and band) |
| The keyboard's patch duplicated play's | `UI::Keyboard::Link::PATCH = Playable::PATCH` | patches drifting apart | adopted (a registry of default patches if a third appears) |
| Enter split a recalled multi-line command (item 7) | `UI::EnterSubmits`: completeness of the whole buffer decides, not the cursor's line | editing-position-dependent submits | adopted; Ctrl-J stays Enter because type-ahead arrives as "\n" through ICRNL (the tiles' bin spec caught the first version) |
| Konsole: every held key retriggered (round 3 item 9): repeats after a short OS delay looked like re-strikes forever | `HoldTracker` as a declared per-key state machine; short gaps are always repeats; delays learned retroactively; specs over six OS timings in every note-off mode plus every tracker pair | repeat detection that depends on one assumed delay | adopted |
| Reading the inputrc through Reline's own config made Reline skip its default bindings (pastes stopped rendering; round 3) | `RelineKeys.default_config` reads into a private `Reline::Config` until Reline has read its own; the step-entry and paste specs cover it | side effects on Reline's lazy setup | adopted |
| Ctrl-] from the band lost the line: the band restored SIGWINCH blindly over Reline's handler (round 3) | `UI::Signals.chain/unchain`: a screen restores the old handler only if its own is still in place | screens clobbering later signal handlers | adopted (band and tiles) |
| A palette result's newline scrolled the screen (round 3 item 22) | one writer of frames (`Tiles#write`) that drops raw newlines and warns; one-line flashes; palette output into the REPL pane | control characters in cells; screen output bypassing the owner | adopted (the real fds are the pty while adopted, so other writers land in the pane) |
| Ctrl-] did different things per mode; the overlay swallowed keys; Esc-hold was a hidden sub-state (round 3 items 12, 19, 20) | `Router::TABLE` over every (state, event) pair, prefixes as data, specs per pair and random walks | unhandled or inconsistent keys in any mode | adopted |
| `show` beside the REPL and splits stole focus in REPL mode (found by the extended random walk) | focus pinned to the mode in `Tiles#tile` | keys going to a pane other than the focused one | adopted |
| `ui.keys` raised NoMethodError under the band (round 3 item 8) | `UI::Facade` with `facade_spec.rb` calling every public Tiles/Band method in every mode | mode-dependent NoMethodErrors on `ui.x` | adopted |

## Open and later

- Band at the top loses terminal scrollback for lines scrolled out of a region that doesn't start at row 1 in xterm; iTerm2 has "Save lines to scrollback when an app status bar is present"; Konsole to check.  `at: :bottom` keeps scrollback everywhere, so it is the default since ux-1 (maintainer, 2026-10-17: "so that scrolled lines go into the terminal's scrollback buffer").
- Ambiguous-width glyphs (▶ ● ◉ ○) are wide when a terminal treats ambiguous characters as wide: `UI.glyphs = :ascii` or `MB_SOUND_UI_GLYPHS=ascii`.
- Remaining GVL coupling: GC pauses triggered on the painter (allocation-light panes help: the scope's chart is rebuilt per frame), the first full frame, the poll.  A process painter (option 3 in ARCHITECTURE.md) removes all of it; the snapshot contract keeps that a transport change.
- Pager output (`less`) and the band both write to the terminal; the 2 s reassertion repairs the band afterwards.
- Plot axes take ~5 columns and 2 rows of a small scope pane; a bare chart style for live panes would help.
- Tiles (ui-5): not built yet: mouse-drag selection in the REPL pane (y copies the match or the visible text), the kitty protocol by default (`kitty: true` is wired but off), a palette that runs long commands off the input thread, combining characters in the VT (dropped), `:margins` (DECSLRM; the maintainer's decision: only if the native probe wins), pane-level `look:` for non-scope panes.  Native checks (iTerm2, Konsole) are the maintainer's: see the checklist in the ui-5 report.

## ux-r3 session round (2026-10-17)

- **Screen switches** (`ui/switch.rb`, item 41): `UI::Switch::STEPS` declares the steps of every `[from, to]` of `:off`/`:band`/`:tiles`.  Leaving the tiles: `:capture_repl` (the REPL pane's last 40 lines up to the cursor, from `UI::VT`), `:stop_tiles`, `:replay_repl` (printed on the normal screen, which the alternate screen's exit had restored as it was when the tiles started, losing their history), the band's start (its scroll region below them), `:redraw_prompt` (a resize signal when not run by the console).  A switch out of the tiles from another thread (the palette) used to end the console: the tiles' stop closed the pty while Reline waited on it, Reline read end of input, Pry exited.  Such switches are now run by the console (`Switch.defer_to_console`): the line being edited is cleared (Ctrl-E Ctrl-U), `ui :mini` is typed into the REPL, and the line comes back at the next prompt (`Reline.pre_input_hook` + `insert_text`).  Lesson: a pty can only be taken away from Reline while the console is evaluating; anything else that ends a screen goes through the console.  Spec: `spec/bin/sound_ui_switch_spec.rb` (tiles -> band -> tiles via the palette with a half-typed line -> off).  Not done: entering the tiles doesn't seed the REPL pane with the normal screen's lines.
- **Scale lock** (`ui/keyboard/scale_lock.rb`, item 44): `ui.keyboard.scale = scale(:dorian, :d)`; `:degrees` (default: each white key the next degree from the scale note at or above the row's C; black keys the degree above their left white key) or `:snap` (`ui.keyboard.scale_mode = :snap`: nearest scale note); PageUp/PageDown in KEYS cycle `ScaleLock::CYCLE` scales and move the root a fifth; the pane header shows "D dorian".  `Keyboard#note_for` maps notes for play mode and step entry, so sent, captured, and step-entered notes are the ones heard.
