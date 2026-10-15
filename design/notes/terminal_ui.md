# Terminal UI

The live terminal UI for the console (`bin/sound.rb`).  Step 1 (ui-2, 2026-10-15) made plots fast enough for live panes (`fast_ui`, `Plot::Live`; see plotting.md).  Step 2 (ui-3) is the read-only **dashboard band**: a few rows above (or below) Pry, kept out of scrolling with a scroll region, drawn by an in-process painter from per-buffer snapshots.  Step 3 (ui-5, the section "The tiled screen" below) is **`ui :tiles`**: the whole screen owned cell by cell, panes tiled in a split tree around the real Pry/Reline, which runs on an in-process pty and draws into its pane through a terminal model.  CUE and the Deck's other parts wait for later steps.

Background: research-ui-2 d3e30356 (never merged): `research/terminal-ui-2/README.md` (painter measurements on the Linux desktop) and `ARCHITECTURE.md` (layers, three options).  Decisions accepted by the maintainer (2026-10-15): option 1 (in-process painter, native cell grid, "snapshots in, cells out", per-pane rates, `Thread.pass` between panes, never poll `Session#players` per frame); a DECSTBM band first, Pry unchanged; live panes default to quadrants in 256 colors (iTerm2 is throughput-bound at ~2.5 MB/s, so bytes per frame matter; Braille stays available per pane); names `ui` / `ui :deck` / `ui off`, `pane :name do |c, s| ... end`, `layout :name do ... end`, `ui.save`.

## Using it

```ruby
ui                      # the default band: transport, form, tracks, queued, master meters, scope (7 rows)
ui :deck                # 13 rows: adds knobs and CPU per part
ui :mini                # one line: transport and form
ui :band, at: :bottom   # under the scrolling text (also color: :truecolor, look: :scope for Braille)
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

The prompt shows the session's status when one has rendered: `sound.rb 17:3 rec:lead arm:pad 31% MB::Sound(0) >` (bar:beat, recording and armed tracks, render load; `UI.prompt_status_enabled = false` turns it off).  Tab completes track, scene, knob, bus, layout, and pane names after the commands that take them (`go :<Tab>`, `turn :c<Tab>`, `ui :<Tab>`), and lists session names first for any other Symbol.  `now` suggests `ui`; `help :ui` is the topic.

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

**Keys.**  REPL mode: everything goes to Reline (Ctrl-C is SIGINT, as a terminal's line discipline would send; Ctrl-Z suspends the screen and the process group, `fg` takes the screen back).  Ctrl-] toggles NAV: 1-9 (the badges), Tab/Shift-Tab, hjkl focus; z zoom; s/v split below/beside (the new slot shows how to `show` a pane); x close; = equalize; arrows resize by 1, Shift-arrows by 5; u / Ctrl-R undo/redo (100 steps; focus isn't a step); [ ] tabs; PgUp/PgDn/Ctrl-B/Ctrl-F/g/G scroll the REPL's scrollback; / search (smart case, backward; n/N again); y copy (the match's line, else the visible text) with OSC 52; : palette; Ctrl-L redraw; i, Esc, Enter, Ctrl-] back.  The status line shows the mode, the focused pane, hints or the last message, and bar:beat.

**How it works** (generic layers under `ui/screen`, `ui/input`, `ui/viewports`, `ui/themes`, `ui/data_file.rb`; `gem_boundary_spec.rb` keeps them free of MB::Sound outside UI, with an empty adapter list for now):

- `UI::Term`: alternate screen, raw input, bracketed paste, optional mouse/focus/kitty; `#leave` undoes all of it (twice-safe, at_exit, exceptions, Ctrl-Z); a probe fenced by DA1 (DECRQM 2026, ambiguous width by a cursor report after one ambiguous glyph, kitty flags).  Tiles works on dups of the terminal's descriptors.
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

## Open and later

- Band at the top loses terminal scrollback for lines scrolled out of a region that doesn't start at row 1 in xterm; iTerm2 has "Save lines to scrollback when an app status bar is present"; Konsole to check.  `at: :bottom` keeps scrollback everywhere.
- Ambiguous-width glyphs (▶ ● ◉ ○) are wide when a terminal treats ambiguous characters as wide: `UI.glyphs = :ascii` or `MB_SOUND_UI_GLYPHS=ascii`.
- Remaining GVL coupling: GC pauses triggered on the painter (allocation-light panes help: the scope's chart is rebuilt per frame), the first full frame, the poll.  A process painter (option 3 in ARCHITECTURE.md) removes all of it; the snapshot contract keeps that a transport change.
- Pager output (`less`) and the band both write to the terminal; the 2 s reassertion repairs the band afterwards.
- Plot axes take ~5 columns and 2 rows of a small scope pane; a bare chart style for live panes would help.
- Tiles (ui-5): not built yet: mouse-drag selection in the REPL pane (y copies the match or the visible text), the kitty protocol by default (`kitty: true` is wired but off), keys for panes themselves (pane keymaps in NAV), a palette that runs long commands off the input thread, combining characters in the VT (dropped), `:margins` (DECSLRM; the maintainer's decision: only if the native probe wins), pane-level `look:` for non-scope panes.  Native checks (iTerm2, Konsole) are the maintainer's: see the checklist in the ui-5 report.
