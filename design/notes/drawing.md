# Drawing: graphs, racks, and lanes on one path

<!-- summary -->
Every terminal drawing goes one way: Plot builds cells into an `MB::Term` grid, the console prints a grid's lines, and UI panes blit a grid into the screen's grid (`Plot::Live#draw`, `Plot::Graph#draw`), so overlays stay on top and nothing writes its own bytes.  `Plot.graph(node)` (`node.draw`, `rack(:dub).draw`, scripts' `-g/--graph`) lays a graph out by rank: boxes from inputs on the left to the output on the right, typed wires (audio solid, control dotted, notes dashed, feedback double under the boxes), port names on slots, constants inline.  It replaced graphviz (retired, racks-v-2).  The layout (`Plot::Graph`, frozen, generic) is built once off the painter; the `:rack` pane (`ui :session`, under the racks) draws a rack instance's ports, knobs, slots, and inner graph from its `RackInfo`.  Lanes (`view`/`lanes`) are the next slice.
<!-- /summary -->

## Quick reference

- `node.draw` (any Traversable) or `MB::Sound::Plot.graph(node)` returns a `Plot::Graph` that prints itself in Pry; `#lines(color:)`, `#to_s`, `#show`, `#save('g.txt' | 'g.ans' | 'g.html')`, `#size`; `rack(:dub).draw` draws a rack's inside on stand-ins, its ports as the left edge; `Session#graph_view.draw` the session (players into the master chain; `Plot.graph(replace: { node => node })`); scripts' `-g/--graph` print the graph (or the song's session) at the start.
- The rack pane: under the racks in `ui :session` (racks-v-2), or `ui.show :rack` in other tiles (it follows the racks pane's picked knob's instance; in its mode arrows pan the drawing, Shift by a quarter of the pane, Home back, `n`/`p` the next or previous instance).
- Code: `lib/mb/sound/plot/graph.rb` (generic layout and text drawing), `lib/mb/sound/plot/graph_view.rb` (mb-sound's side: graph walks to boxes and wires); `lib/mb/sound/ui/rack_pane.rb` (`Panes::RackDetail`); specs `spec/lib/mb/sound/plot/graph_spec.rb` (every graph sweep factory lays out and draws), `spec/lib/mb/sound/ui/rack_pane_spec.rb`; help `help :racks`, `help :plots`.

Phase V of the racks proposal (`research-racks`, `research/racks/PROPOSAL.md` section 5 and row V of section 7; approved with the rest by the maintainer, 2026-10-17: "Racks look good; go ahead"), the roadmap's "Drawing consolidation (racks V)": "One UI code path for plots, `vis`, racks, graph drawings and lanes: a rack pane, `Plot.graph` rank layout, `view`/`lanes` stacked on one time axis, the live lanes pane."  First slice (racks-v-1, 2026-11-15): this note, `Plot.graph`, and the rack pane; racks-v-2 (2026-11-21) applied the maintainer's answers to its questions (below): the rack pane in `ui :session`, graphviz retired.  Left for the next slices: `view`/`lanes`, the live lanes pane, owner groups, typed panels inside the boxes, `highlight: :plan`, SVG/PNG drawings of graphs.

## The one drawing path

| Drawing | Built by | Cells from | Console | Pane |
|---|---|---|---|---|
| charts and figures (plots, `vis`, spectra, previews) | `Plot.chart`/`figure`, presets, `Plot::Panels` | `Text::Frame` (layout once, marks per frame) | `Renderable#show`/`lines` | `Plot::Live#draw(chart, grid, x:, y:)` blits |
| graph drawings | `Plot.graph(node)` -> `Plot::Graph` (layout and picture once) | `Plot::Graph#draw` (runs of styled cells, `put_run` as `UI::Canvas` writes) | `Plot::Graph#show`/`lines` (a `MB::Term::Cells` grid) | `Plot::Graph#draw(grid, x:, y:, w:, h:, scroll:)` writes the window into the screen's grid |
| lanes (next slice) | `view`/`lanes` -> a Figure of lanes sharing one `Plot::Scale::Time` and gutter | `Text::Frame`, `Mark::Notes` | as charts | `Plot::Live#draw` |

- A drawing never writes terminal bytes: it fills a grid of the screen's class (`Kernels.cell_grid`, or the class of the pane's grid), and the screen's one frame writer sends the changed cells (terminal_ui.md: panes never write their own bytes, ui-fix-3).  The console prints the same grid's lines in the terminal's color mode, so a pane and `node.draw` show the same picture.
- Colors are UI roles (`MB::Term::Themes`, the theme the tiles use: `:text`, `:dim`, `:name`, `:key`, `:warn`, `:band_mod`), resolved when the drawing fills its grid: a graph drawn in the console wears the current UI theme, and `color: :none` gives plain text for specs and `.txt` files.
- Static vs. per frame (the UI owner's contract, racks.md "Agreed follow-ups"): `Plot::Graph` holds the layout (boxes, columns, rows, wire routes) built once, frozen and Ractor-shareable, off the painter (a rack's comes from its stand-in build, remembered per Rack beside its latency); per frame a pane only blits a window of it.  Live values in the boxes (taps with Session stamps) come with the lanes slice and redraw only the cells they own.

What it replaces: `graphviz`/`open_graphviz` (DOT text and a PNG through the system's `dot`, since the first videos), retired in racks-v-2 by the maintainer's answer "retire" (2026-11-21): every caller moved to `node.draw` (the script runner's `-g/--graphviz` is `-g/--graph`, printing the drawing; `Session#graph_view` draws through `#draw`), and what only graphviz used went with them (`to_s_graphviz` on two dozen node classes, `Traversable.channel_boxes`, `ChannelGroup#label`, Reverb's `show_internals:` and `#graphviz_internals`, `include_tees:`/`expand_channels:`), as did the `graphviz` package in the Dockerfile, CI, and the README (nothing else used `dot`).  What graphviz drew that `node.draw` doesn't yet is under known gaps.  `UI::TreeText` (the buses pane's routing tree) stays a tree (question 4).  The racks pane stays the list of instances with their knobs to turn; the rack pane is its detail, as the clip detail is the matrix's.

## `Plot.graph`: the rank layout

`Plot::Graph` is generic (plot boundary: no mb-sound types) and takes boxes and wires; `Plot.graph` (mb-sound's side, `graph_view.rb`) walks a graph into them.

**The walk** (from the node, or every channel of a bundle, through `#sources` and `#feedback_sources`):

- Plumbing folds away: Tees and their branches (a node read in several places is one box with a wire per reader), knob readers into their knob, and the outputs of a multi-output node into one box with an output slot each (`port_info[:out]`: `out_1`, `out_2`, ...), its own edges to and from its outputs left out.
- Numbers and Constants read by one input show inline on the input's slot (`cutoff 1200`); a Constant read in several places is a box.
- Boxes say what the node is in DSL words: its name, else the recipe's method (`filter`, `delay`, `duck`), arithmetic as `+`/`×`/the operator, a tone's wave, a knob's name, else its type in words (`Traversable.words_of` at depth 0); never a class name.
- Input slots are `port_info[:in]` in order (main inputs first as the node lists them), each wire typed by its edge (`:audio`, `:control`, `:notes`) and dimmed when `port_active?` is false.  Feedback edges (`feedback_sources`; a feedback loop's variable reads its loop as one since this slice) get slots after the others.
- A rack's stand-ins become port boxes at the left edge, named by the port (`sig`, `side`, `keys`), their main and side wires typed by the port's declared type (`port_types:`; a stand-in is a Constant, which would read as control), and its result feeds an `out` box at the right (an input per channel of a bundle).

**The layout** (Sugiyama-style, deterministic):

1. Columns by the longest path to an output (feedback edges and any cycle's back edges left out), so a node sits as close to what reads it as its other readers allow, inputs on the left; port boxes in the first column, the output last.
2. A wire skipping columns passes through one-row placeholders in the columns between (drawn faded: "wires that skip ranks drawn faded and behind").
3. Order within columns: start from the walk's order (main inputs first), then barycenter sweeps toward the output and back.
4. Rows: boxes stacked in column order with a blank row between, each pulled toward the rows of the wires it connects (a straight wire where there is room), columns padded so the drawing is about as tall as its tallest column.
5. Gaps between columns hold one vertical track per net (a source slot's wires of one style, so fan-outs branch with `┬├┤`, and an audio and a control wire from one slot keep their looks); crossings of different nets draw the horizontal wire over the vertical.
6. Feedback wires leave the source's output into the gap after it, run along their own lane below every box, and come up the gap before the target into its feedback slot.

**The look** (text cells): a box is a frame with its title set in the top rule, one row per input slot (an arrowhead `▸` where a wire arrives, the slot's name, an inline value in the value color), and output slots on its right edge (`├` where a wire leaves; several outputs numbered).  Wires: audio `─│` solid, control `┄┆` dotted, notes `╌╎` dashed in the note hue, feedback `═║` double in the warning color, skipped ranks dim.  `glyphs: :ascii` draws `- | + > =`.  Titles and slot names are cut to 18 and 14 columns with an ellipsis.

## The rack pane

`Panes::RackDetail` (`:rack`, a set pane beside `:racks`, so not on the `:wall`; the lower half of `ui :session`'s racks column since racks-v-2, the maintainer's answer "yes" to question 2, 2026-11-21; elsewhere `ui.show :rack`): the instance the racks pane's pick is on (else the first), drawn from `Snapshot#racks` (`Rack::RackInfo`, Poll, no render lock) and knob values from `Snapshot#knobs`:

- header: path (or name), kind, signature, latency;
- ports: typed, optional ones marked `?` (`sig:audio side:audio?`);
- knobs: one row each with its value and range (read-only here: turning stays in the racks pane, which journals `turn` lines);
- slots: `RackInfo#slots` (empty until R3: the line says so);
- the inner graph: `RackInfo#graph`, a `Plot::Graph` of the rack's stand-in build (the rack's definition, the same for every instance), its window written into the screen's grid below the header (a dim `…` in the corner while more lies beyond an edge); in the pane's mode arrows pan it (Shift: a quarter of the pane; Home: back) and `n`/`p` change the instance with a flash (view state only: no Session change, so nothing to journal).
- Lines whose segments run past the edge end in an ellipsis (`RackDetail.line`; `text_fit_spec`).

`RackInfo` gained `graph` (nil when the stand-in build fails; a default, so older constructors keep working); `Rack#graph` builds it once per Rack value from the same stand-in build as the latency (`Rack::GRAPHS` beside `Rack::LATENCIES`).  `Racks.selected` is the instance whose knob the racks pane picked while in its mode (per process, like `Clips.selected`).

## Questions (racks-v-1) and the maintainer's answers (2026-11-21)

1. Instance graphs or the definition?  "Show me a picture of the two options if they both already exist."  Only the definition drawing existed; racks-v-2 made a text capture of a cheap instance drawing (the definition's boxes with each knob's value as an inline slot, `Plot::Graph.new` with the boxes changed: a few lines, a relayout of ~5 ms for the 17-box dub rack on the Mac, so built off the painter when values change, not per frame) beside the definition's (the private UI notes of 2026-11-21-racks-v-2-captures); not built into the pane.
2. The rack pane in a built-in layout: "yes": the lower half of `ui :session`'s racks column (racks-v-2).
3. graphviz beside `node.draw`: "retire": done in racks-v-2 (above).
4. Bus routing drawn by `Plot.graph` instead of a tree: "If it ever supports loops."  It does: forward wires that close a cycle are drawn as feedback (their back edge on its own lane under the boxes; `graph_spec` "draws a cycle among forward wires as feedback"), and bus routing can't loop anyway (`to:`, `feed`, and readers refuse a loop through `live_error`; one that slipped through warns and reads silence; buses.md).  Converting the buses pane is a note for later, not built.
5. Knobs inline: "knobs can stay boxes for now."

## Questions (racks-v-2, for the maintainer)

1. The instance drawing (captures in the private UI notes of 2026-11-21-racks-v-2-captures: `rack_dub_instance.txt` beside `rack_dub_definition_graph.txt`): build it into the rack pane (knob values as an inline slot on each knob box, relaid out off the painter when a value changes), or keep the definition?
2. Image files of drawings (SVG/PNG through Plot's renderers, for the blog and videos), or are `.html`/`.ans` enough?
3. `ChannelGroup` keeps a per-channel call's members, inputs, per-channel arguments, and argument nodes, which only graphviz read (LiteralBinding reads `bundle`): fold each per-channel call into one box in `Plot.graph` as graphviz did, or drop the unread fields?
4. Reverb's network inside its box (the old `show_internals:`): draw it in `Plot.graph` later, or leave it gone?
5. The rack pane moved the NAV numbers of the panes after it in `ui :session` (clip matrix 8 to 9, clip detail 9 to 10, MIDI 10 to 11, landed 11 to 12): keep, or give the rack pane the last number?

Known gaps (for the next slices): what graphviz drew that `node.draw` doesn't: image files (SVG/PNG; `Plot::Graph#save` writes .txt, .ans, and .html, whose colored text is the closest to a picture), one box per per-channel DSL call (`ChannelGroup` keeps the call's members, inputs, per-channel arguments, and argument nodes for such a fold; `node.draw` draws every channel), a reverb's network inside its box (the old `show_internals:`; `Reverb#layout` has it), and a per-node detail line (`to_s_graphviz` listed a filter's type and Q, a delay's interpolation; slot values and the typed panels cover part); settings a node keeps as plain numbers rather than inputs don't show (`lp4(1200)` lists no cutoff in `#sources`; the typed panels from `param_snapshot`/`preview_data` will show them); a Synth draws every lane (an irack's drawing is ~150 boxes: owner groups collapse them); long rank-skipping wires make drawings wide (owner groups and panning help; no compaction yet); the layout is only as good as a few barycenter sweeps (no transposition step).
