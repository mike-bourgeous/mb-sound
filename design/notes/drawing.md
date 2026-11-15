# Drawing: graphs, racks, and lanes on one path

<!-- summary -->
Every terminal drawing goes one way: Plot builds cells into an `MB::Term` grid (`NativeCells` or the Ruby `Cells`), the console prints a grid's lines, and UI panes blit a grid into the screen's grid (`Plot::Live#draw`, `Plot::Graph#draw`), so overlays stay on top and nothing writes its own bytes.  `Plot.graph(node)` (console `node.draw`, `rack(:dub).draw`) lays a graph out by rank: boxes in columns from inputs on the left to the output on the right, typed wires (audio solid, control dotted, notes dashed, feedback double lines routed under the boxes), port names on input slots, constants inline, fanned outputs of multi-output nodes.  The layout (`Plot::Graph`, frozen, generic) is built once off the painter; the `:rack` pane draws a rack instance's ports, knobs, slots, and inner graph from its `RackInfo`.  Lanes (`view`/`lanes`) and the live lanes pane are the next slice.
<!-- /summary -->

## Quick reference

- `node.draw` (any Traversable) or `MB::Sound::Plot.graph(node)` returns a `Plot::Graph` that prints itself in Pry; `#lines(color:)`, `#to_s`, `#show`, `#save('g.txt' | 'g.ans' | 'g.html')`, `#size`; `rack(:dub).draw` draws a rack's inside on stand-ins, its ports as the left edge.
- The rack pane: `ui.show :rack` in the tiles (it follows the racks pane's picked knob's instance; arrows pan the drawing in its mode, `n`/`p` the next or previous instance).
- Code: `lib/mb/sound/plot/graph.rb` (generic layout and text drawing), `lib/mb/sound/plot/graph_view.rb` (mb-sound's side: graph walks to boxes and wires); spec `spec/lib/mb/sound/plot/graph_spec.rb` (every graph sweep factory lays out and draws).

Phase V of the racks proposal (`research-racks`, `research/racks/PROPOSAL.md` section 5 and row V of section 7; approved with the rest by the maintainer, 2026-10-17: "Racks look good; go ahead"), the roadmap's "Drawing consolidation (racks V)": "One UI code path for plots, `vis`, racks, graph drawings and lanes: a rack pane, `Plot.graph` rank layout, `view`/`lanes` stacked on one time axis, the live lanes pane."  First slice (racks-v-1, 2026-11-15): this note, `Plot.graph`, and the rack pane.  Left for the next slices: `view`/`lanes`, the live lanes pane, owner groups, typed panels inside the boxes, `highlight: :plan`, SVG/PNG drawings of graphs.

## The one drawing path

| Drawing | Built by | Cells from | Console | Pane |
|---|---|---|---|---|
| charts and figures (plots, `vis`, spectra, previews) | `Plot.chart`/`figure`, presets, `Plot::Panels` | `Text::Frame` (layout once, marks per frame) | `Renderable#show`/`lines` | `Plot::Live#draw(chart, grid, x:, y:)` blits |
| graph drawings | `Plot.graph(node)` -> `Plot::Graph` (layout and picture once) | `Plot::Graph#draw` (runs of styled cells, `put_run` as `UI::Canvas` writes) | `Plot::Graph#show`/`lines` (a `MB::Term::Cells` grid) | `Plot::Graph#draw(grid, x:, y:, w:, h:, scroll:)` writes the window into the screen's grid |
| lanes (next slice) | `view`/`lanes` -> a Figure of lanes sharing one `Plot::Scale::Time` and gutter | `Text::Frame`, `Mark::Notes` | as charts | `Plot::Live#draw` |

- A drawing never writes terminal bytes: it fills a grid of the screen's class (`Kernels.cell_grid`, or the class of the pane's grid), and the screen's one frame writer sends the changed cells (terminal_ui.md: panes never write their own bytes, ui-fix-3).  The console prints the same grid's lines in the terminal's color mode, so a pane and `node.draw` show the same picture.
- Colors are UI roles (`MB::Term::Themes`, the theme the tiles use: `:text`, `:dim`, `:name`, `:key`, `:warn`, `:band_mod`), resolved when the drawing fills its grid: a graph drawn in the console wears the current UI theme, and `color: :none` gives plain text for specs and `.txt` files.
- Static vs. per frame (the UI owner's contract, racks.md "Agreed follow-ups"): `Plot::Graph` holds the layout (boxes, columns, rows, wire routes) built once, frozen and Ractor-shareable, off the painter (a rack's comes from its stand-in build, remembered per Rack beside its latency); per frame a pane only blits a window of it.  Live values in the boxes (taps with Session stamps) come with the lanes slice and redraw only the cells they own.

What it replaces: the graph drawing replaces nothing yet; `graphviz`/`open_graphviz` stay for pictures through dot (question 3).  `UI::TreeText` (the buses pane's routing tree, "meant to be shared with the planned rack pane") stays a tree: routing has no ranks worth a layout (question 4).  The racks pane stays the list of instances with their knobs to turn; the rack pane is its detail, as the clip detail is the matrix's.

## `Plot.graph`: the rank layout

`Plot::Graph` is generic (plot boundary: no mb-sound types) and takes boxes and wires; `Plot.graph` (mb-sound's side, `graph_view.rb`) walks a graph into them.

**The walk** (from the node, or every channel of a bundle, through `#sources` and `#feedback_sources`):

- Plumbing folds away: Tees and their branches (a node read in several places is one box with a wire per reader), knob readers into their knob, and the outputs of a multi-output node into one box with an output slot each (`port_info[:out]`: `out_1`, `out_2`, ...), its own edges to and from its outputs left out.
- Numbers and Constants read by one input show inline on the input's slot (`cutoff 1200`); a Constant read in several places is a box.
- Boxes say what the node is in DSL words: its name, else the recipe's method (`filter`, `delay`, `duck`), arithmetic as `+`/`×`/the operator, a tone's wave, a knob's name, else its type in words (`Traversable.words_of` at depth 0); never a class name.
- Input slots are `port_info[:in]` in order (main inputs first as the node lists them), each wire typed by its edge (`:audio`, `:control`, `:notes`) and dimmed when `port_active?` is false.  Feedback edges (`feedback_sources`; a feedback loop's variable reads its loop as one since this slice) get slots after the others.
- A rack's stand-ins become port boxes at the left edge, named by the port (`sig`, `side`, `keys`), and its result feeds an `out` box at the right.

**The layout** (Sugiyama-style, deterministic):

1. Columns by the longest path to an output (feedback edges and any cycle's back edges left out), so a node sits as close to what reads it as its other readers allow, inputs on the left; port boxes in the first column, the output last.
2. A wire skipping columns passes through one-row placeholders in the columns between (drawn faded: "wires that skip ranks drawn faded and behind").
3. Order within columns: start from the walk's order (main inputs first), then barycenter sweeps toward the output and back.
4. Rows: boxes stacked in column order with a blank row between, each pulled toward the rows of the wires it connects (a straight wire where there is room), columns padded so the drawing is about as tall as its tallest column.
5. Gaps between columns hold one vertical track per net (a source slot and every wire from it, so fan-outs branch with `┬├┤`); crossings of different nets draw the horizontal wire over the vertical.
6. Feedback wires leave the source's output into the gap after it, run along their own lane below every box, and come up the gap before the target into its feedback slot.

**The look** (text cells): a box is a frame with its title set in the top rule, one row per input slot (an arrowhead `▸` where a wire arrives, the slot's name, an inline value in the value color), and output slots on its right edge (`├` where a wire leaves; several outputs numbered).  Wires: audio `─│` solid, control `┄┆` dotted, notes `╌╎` dashed in the note hue, feedback `═║` double in the warning color, skipped ranks dim.  `glyphs: :ascii` draws `- | + > =`.  Titles and slot names are cut to 18 and 14 columns with an ellipsis.

## The rack pane

`Panes::Rack` (`:rack`, a set pane beside `:racks`; `ui.show :rack`): the instance the racks pane's pick is on (else the first), drawn from `Snapshot#racks` (`Rack::RackInfo`, Poll, no render lock) and knob values from `Snapshot#knobs`:

- header: path (or name), kind, signature, latency;
- ports: typed, optional ones marked `?` (`sig:audio side:audio?`);
- knobs: one row each with its value and range (read-only here: turning stays in the racks pane, which journals `turn` lines);
- slots: `RackInfo#slots` (empty until R3: the line says so);
- the inner graph: `RackInfo#graph`, a `Plot::Graph` of the rack's stand-in build (the rack's definition, the same for every instance), blitted below the header; in the pane's mode arrows pan it and `n`/`p` change the instance (view state only: no Session change, so nothing to journal).

`RackInfo` gained `graph` (nil when the stand-in build fails); `Rack#graph` builds it once per Rack value together with the latency.

## Questions (racks-v-1, for the maintainer)

1. The rack pane draws the rack's definition (its stand-in build), not each instance's graph: instances differ only in bound ports and knob values, which the header shows.  Instance graphs (live values on the boxes) come with taps in the lanes slice.  Or draw instances now?
2. The rack pane isn't in a built-in layout (`ui.show :rack` opens it); `ui :session` could give it the racks column's lower half (golden captures change).  Which?
3. `graphviz`/`open_graphviz` stay beside `node.draw`; the proposal's SVG/PNG graph drawings through Plot's renderers would replace `open_graphviz` later.  Keep both, or retire graphviz once SVG drawings exist?
4. Bus routing (`UI::TreeText`) stays a tree; `Plot.graph` could draw buses and sends as boxes and wires later.
5. Constants read once show inline; knobs stay boxes.  Inline knobs too (`cutoff ◂ tone 2400`), as the inspector shows them?
