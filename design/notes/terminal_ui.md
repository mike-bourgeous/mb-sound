# Terminal UI

The live terminal UI for the console (`bin/sound.rb`).  Step 1 (ui-2, 2026-10-15) made plots fast enough for live panes (`fast_ui`, `Plot::Live`; see plotting.md).  Step 2 (ui-3, this note) is the read-only **dashboard band**: a few rows above (or below) Pry, kept out of scrolling with a scroll region, drawn by an in-process painter from per-buffer snapshots.  Tiling, owning the whole screen (the Deck), global keys, and CUE wait for later steps.

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

## Open and later

- Band at the top loses terminal scrollback for lines scrolled out of a region that doesn't start at row 1 in xterm; iTerm2 has "Save lines to scrollback when an app status bar is present"; Konsole to check.  `at: :bottom` keeps scrollback everywhere.
- Ambiguous-width glyphs (▶ ● ◉ ○) are wide when a terminal treats ambiguous characters as wide: `UI.glyphs = :ascii` or `MB_SOUND_UI_GLYPHS=ascii`.
- Remaining GVL coupling: GC pauses triggered on the painter (allocation-light panes help: the scope's chart is rebuilt per frame), the first full frame, the poll.  A process painter (option 3 in ARCHITECTURE.md) removes all of it; the snapshot contract keeps that a transport change.
- Pager output (`less`) and the band both write to the terminal; the 2 s reassertion repairs the band afterwards.
- Plot axes take ~5 columns and 2 rows of a small scope pane; a bare chart style for live panes would help.
