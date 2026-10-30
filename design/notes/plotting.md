# Plotting

<!-- summary -->
`MB::Sound::Plot` (`lib/mb/sound/plot/`) draws every plot in pure Ruby (no gnuplot; `spec/support/no_gnuplot.rb` fails specs that start it): Scales -> Coords -> Marks -> guides -> Chart/Figure -> renderers for terminal text (looks `Plot::Text::LOOKS`, Braille `:scope` by default), SVG, PNG, and inline images.  Build with `Plot.chart { x :time; line data }`, `Plot.figure { chart { ... } }`, the presets (`Plot.waveform`, `spectrum`, ...), or the console's `chart`/`figure`/`plot`; charts `show`, `to_svg`, and `save('x.svg' | .png | .txt | .ans | .html)`.  Live panes use `Plot::Live` over the C text kernels in `fast_ui` (exact mirrors of the Ruby; `MB_SOUND_PLOT=ruby`), and UI panes never write their own bytes.
<!-- /summary -->

Quick reference: the text looks are `Plot::Text::LOOKS` (`:scope` Braille, `:blocks`, `:mosaic`, `:quad`, `:spark`, `:ascii`); builders `Plot.chart(title:) { ... }` and `Plot.figure { chart { ... } }`; charts `save('x.svg' | .png | .txt | .ans | .html)`; live panes `Plot::Live.new(width:, height:, look:)` with `#redraw(chart)`, `#frame(chart, row:, col:)` / `#write(io, chart, ...)`, and `#draw(chart, grid, x:, y:)`, which blits into a screen grid so overlays stay on top (`overlay_guard_spec.rb`).

`MB::Sound::Plot` (`lib/mb/sound/plot.rb`, `lib/mb/sound/plot/`) draws every plot in mb-sound in pure Ruby, from Numo arrays, with no external process.  Built 2026-10-11 on branch `plot-1` after a gnuplot output race made `plot_methods_spec.rb:169` flaky (gnuplot's end-marker echo leaked into captured output); the maintainer asked to "bump up the priority of our custom plotting code and remove gnuplot usage", with "a few variations" and "a good architecture for scales axes legends etc."  mb-math's gnuplot pipe (`MB::M::Plot`) is untouched but no longer used by mb-sound; `spec/support/no_gnuplot.rb` fails any spec that starts it.  No gnuplot fallback was kept: PlotMethods builds charts directly now, so a fallback could only have covered the old Hash interface (a `plotter` override with MB::M::Plot's `#plot` still works for the Hash-based methods).

## Layers

A small grammar of graphics, all plain Ruby objects:

- **Scales** (`plot/scale.rb`): map data to 0..1 and make ticks (`Tick` = value, label, major).  `Linear` (nice domains when fit), `Symmetric` (waveforms, -m..m), `DB` (floor -120 so silence fits; fitted domains never go below the floor), `Log`, `Frequency` (log Hz labeled 100, 1k, 10k, plus secondary note-name ticks for every C, every other C past 9 octaves, or every `notes: n` semitones, at `a4:` tuning), `Time` (data in seconds, or in samples with `sample_rate:`; labels in s/ms/µs from the domain's size; `unit: :samples`; `unit: :bars` with beats), `Categorical`.  A scale without a domain is fit to the chart's data (`#fit`); scales are immutable.  `Scale.build` takes a Scale, a Range (linear domain), or a kind Symbol plus keywords (the builder's `x`/`y`).
- **Format** (`plot/format.rb`): nice steps (1, 2, 5 x 10^k), shared decimals per axis, SI prefixes (`si: true` both ways, `:up` only k/M/G), no negative zero, bare "0" on prefixed axes.
- **Coords** (`plot/coord.rb`): `Cartesian`, `Polar` (x is the angle in turns of its domain, y the radius; text panels keep it square, rings and spokes instead of axes).
- **Marks** (`plot/mark.rb`): `Line` (`step: true` staircase), `Area` (filled to `base:`), `Points`, `Stems`, `Band` (between two lines), `Rule` (reference line, muted), `Heatmap` (rows bottom to top, `x:`/`y:` Ranges, `z_scale:` (e.g. `Scale::DB`), `colormap:`; sampled through the scales' `invert`, so a log frequency axis over linear FFT bins just works).  Marks draw through a small surface protocol (polyline with NaN gaps, points, area, band, image grid) that each renderer implements.
- **Decimation** (`Geometry.decimate` in `plot/raster.rb`): lines with more than two points per device column become each column's min and max, in the order the signal crossed them.  Text rasters put both at the rounded column (groups a little under a column apart, so no column is skipped); vector output puts them at each group's first and last x (smooth steep slopes).  Evenly spaced x (index or Range) decimates fully vectorized; other monotonic x (log frequency) loops over columns.
- **Guides**: drawn by the renderers from the scales and marks: title row with the y axis title and the legend (right-aligned; in the image renderers a legend that doesn't fit beside the title wraps onto rows under it, like the text renderer (omnibus5: it drew over long titles); shown for two or more labeled series, or one without a title, or with `legend: true`), y tick labels, x axis with tick marks, x tick labels with the x axis title (with its unit) taking precedence at the right, a note-name row for frequency axes, a colorbar for heatmaps.
- **Chart / Figure** (`plot/chart.rb`): a Chart is one panel (scales, marks, legend, grid, polar); a Figure lays charts in a grid (default about square; `columns:`/`rows:`).  Builders: `Plot.chart(title:) { x :time, sample_rate: 48000; line data, label: 'saw' }` (`instance_exec` for blocks without arguments, so typos get did_you_mean; a block with an argument gets the builder), `Plot.figure { chart { ... }; chart { ... } }`.  Palette slots go to series in order (fixed order, never cycled: a ninth series reuses slot 1).
- **Renderers**: `Plot::Text` (terminal), `Plot::SVG`, `Plot::Image` (PNG, sixel, kitty, iTerm2).  `Renderable` gives charts and figures `to_s`, `lines`, `to_svg`, `to_png`, `save(path)` (by extension: .svg, .png, .txt, .ans, .html), `show` (text, or an inline image with `image: true`), and `pretty_print` (Pry and IRB show a returned chart).

## Terminal text (`plot/text.rb`)

Marks draw into a `Raster` of sub-cell dots holding color indexes with priorities (lines over fills over grid); a canvas turns each cell's dots into one character:

| look | canvas | dots per cell | colors per cell | frame |
|---|---|---|---|---|
| `:scope` (default) | Braille | 2x4 | 1 | box axes, dotted grid |
| `:blocks` | half blocks | 1x2 | 2 (true per-pixel color) | box axes, lines filled to 0 |
| `:mosaic` | sextants (Unicode 13 legacy computing) | 2x3 | 2 | labels only |
| `:quad` | quadrants | 2x2 | 2 | box axes |
| `:spark` | eighth blocks (reverse video for tops) | 1x8 | 1 | none, filled, hi/lo labels |
| `:ascii` | `' - . \| :` | 1x3 | none | ASCII axes |

Heatmaps always draw as half blocks (two colormap colors per cell, foreground and background), with line characters over them; without color they are shaded `░▒▓█`.  Fills look one step dimmer than their line.  Color modes `:truecolor`, `:ansi256`, `:ansi16`, `:none`; SGR strings are cached per style and emitted only on change.  Output is deterministic (no terminal queries, no processes), so specs compare it exactly (`spec/lib/mb/sound/plot/text_spec.rb` has an ASCII snapshot).

`Plot::Terminal` reads the environment only: `PLOT_WIDTH`/`PLOT_HEIGHT` (size), `PLOT_COLOR` (truecolor/256/16/none), `NO_COLOR`, `COLORTERM`, `TERM`, `TERM_PROGRAM` (iTerm.app, WezTerm, vscode), `KONSOLE_VERSION`, `KITTY_WINDOW_ID`; `PLOT_LOOK`; `PLOT_THEME` or `COLORFGBG` for dark/light; `PLOT_IMAGES` (sixel, kitty, iterm, or 1 for the detected one) to show plots as inline images by default.  Image protocols: iTerm2 (`TERM_PROGRAM=iTerm.app`, `LC_TERMINAL=iTerm2`, WezTerm), kitty (`KITTY_WINDOW_ID`, ghostty), sixel (Konsole 22.04+); inside tmux the escape is wrapped for passthrough (needs `set -g allow-passthrough on`).  Not verified on the maintainer's iTerm2 or Konsole yet.

## Images

`PixelLayout` (`plot/layout.rb`) places titles, legends, axes, grid, colorbars, and plot areas in pixels for both image renderers through a painter protocol (rect, line, text, text_width, plot area, optional vgradient).

- **SVG** (`plot/svg.rb`): pure Ruby strings; heatmaps as embedded PNGs of at most `heatmap_pixels:` (600x300 default, scaled smoothly by the viewer); colorbars as one linearGradient; series get `<title>` tooltips; the phosphor theme adds a glow filter.  Element ids get a fresh `mbplotN-` prefix per render (or `id_prefix:`), so SVGs inlined in one HTML page don't share clip paths or gradients (found 2026-10-11 by the main session: the studio and phosphor spectrograms showed paper's colormap).  Text widths are estimates (0.6 em, 0.68 for bold).
- **Image** (`plot/image.rb`): a Float RGB buffer; lines and points clipped to their plot area plus 2 px like the SVG renderer's clip paths (omnibus5: data beyond the y domain drew over titles and other panels; the clip is in the surface's polyline, so it covers stems, rules, and area/band outlines too, while fills and heatmaps are drawn at plot size; omnibus6 checked a report of stems spilling below their panel and couldn't reproduce it at 8eca1881 in PNG, SVG, or text, and added `image_spec` examples for stems (base 0 and on the floor), lines, points, area, band, rules, and heatmaps beyond the domain, in PNG (no changed pixels outside the plot area) and SVG (inside the plot's clip group); without the clip five of them fail); antialiased lines by splatting samples every 0.25 px with bilinear weights through `bincount`; fills through the same Raster column fills; text from a DejaVu Sans Mono 12 px bitmap font (8x16 cells, 4-bit alpha, ASCII plus µ · …; other characters draw as `Font::FALLBACKS` stand-ins (dashes, quotes, ×, °, ...) or an accented letter's base letter, else '?'; omnibus5) generated by `lib/mb/sound/plot/make_font.rb` with ffmpeg's drawtext (Bitstream Vera license allows derivatives); PNG encoded with Zlib (standard library).  Chosen over ffmpeg for PNG because images then need no process, render the same everywhere (ffmpeg's SVG decoder needs librsvg, which the Mac's Homebrew ffmpeg may lack), and the same pixels feed the inline terminal protocols.  Sixel quantizes to 6x7x6 levels.

Themes (`plot/theme.rb`): categorical palettes from the data-viz reference palette (validated for color vision deficiencies in this order; light steps for light surfaces, dark steps for dark, and brighter steps for thin terminal glyphs on dark terminals); colormaps `:magma` (text and paper), `:inferno` (studio), `:viridis`, `:blues`, `:phosphor`, `:gray` (64 steps, from ninths of matplotlib's maps).  Image themes `:paper` (light, serif), `:studio` (dark), `:phosphor` (oscilloscope green with glow); terminal themes `:dark`, `:light`.

## mb-sound integration

- `PlotMethods#plotter` returns `Plot::Plotter`, an MB::M::Plot-compatible facade: `plot(Hash, rows:, columns:, print:)` (data arrays, `[x, y]` pairs, 2D arrays as heatmaps; `:xrange`, `:yrange`, `:logscale`, `:type` ('lines', 'points', 'steps', 'impulses', 'boxes', 'filledcurves'), `:x`, `:x_label`), `xrange`, `yrange`, `logscale`, `print`, `width`, `height` (live from the terminal unless fixed), `save_image`, `close`, plus `draw(chart_or_figure)`.  `command` raises (no gnuplot).  Graphical plotters show inline images where detected, else text at the terminal's size.
- `plot`, `spectrum`, `time_freq`, `mag_phase`, `hist` keep their signatures and Hash-based panels (x is the sample index for time panels; frequency panels of `plot(spectrum: true)`/`spectrum`, `time_freq`, and `mag_phase` are in Hz on `Plot.spectrum`'s log axis with note names since omnibus6 (agreed 2026-10-12), DC left out, at the tone's/node's/filter's rate or `sample_rate:` (48 kHz); `logarithmic: false` gives a linear Hz axis; the Plotter's Hash panels take `x_scale:` for this); `overlay` (and `hist(density:/pdf:)`) builds a Figure with legends; new `chart`, `figure`, `spectrogram(sound, seconds:, fft:, hop:, floor:, log:, colormap:)`.
- `PlotOutput` (play's live plot and `vis`): with a `#draw` plotter, `Plot.waveform` (time axis, a legend entry per channel, symmetric range that grows like before) or `Plot.spectrum` (Hann, log frequency with note names, -90..0 dB); other plotters get the old Hash calls.
- Presets (`plot/presets.rb`): `Plot.waveform`, `Plot.spectrum` (Hann window, scaled so a full-scale sine on a bin reads 0 dB), `Plot.spectrogram` (STFT, `fft: 2048`, `hop: fft / 4`, top level rounded up to 6 dB, `floor: -90`), `Plot.envelope` (`db:` range).
- Scripts: `bin/plot_envelope.rb` (every curve in one chart with a legend; `-I` inline image, `-S file` save; `-t` kept as a no-op), `bin/plot_curves.rb` (up to six curves in one chart, more as panels; `-I`, `-S`), `bin/plot_waveforms.rb` (text by default; `-I`, `-S`, `--width`/`--height` are image pixels), `bin/plot_windows.rb`, `bin/plot_noise.rb` (`-g` inline image), `bin/plot.rb`, `bin/plot_resampler*.rb`, `bin/fir_filter.rb`, `bin/haas_pan.rb`.  `bin/plot_gallery.rb` renders every look and theme on the same sounds (`--compact` for a ~300 KB page; `--show LOOK` in the terminal).
- Gallery (2026-10-11): `/app/tmp/plot-gallery/index.html` (full, ~1.5 MB) and `/app/tmp/plot-gallery-compact/index.html` (~300 KB), with raw `.ans` captures and `.svg` files; regenerate with `bin/plot_gallery.rb [--compact] -o DIR`.

## Measurements (2026-10-11, container, YJIT)

Live frames (`PlotOutput#plot`, stereo 800-sample buffers, 120x45 cells, truecolor, output to a StringIO; the old path was gnuplot's dumb terminal through a pipe, no color):

| look | waveform | spectrum |
|---|---|---|
| scope | 138 fps (7.3 ms) | 187 fps (5.4 ms) |
| blocks | 171 | 213 |
| mosaic | 160 | 202 |
| spark | 102 | 130 |
| ascii | 205 | 254 |
| gnuplot dumb (old) | 62 (16 ms) | 70 (14 ms) |

End to end, `vis` on a NullOutput Session (800-sample buffers, 60 per second, 120x45, 3 s): 57-59 fps for scope and blocks, waveform and spectrum, which is every buffer; the same run through gnuplot's dumb terminal drew 42 fps for the waveform (dropping buffers) and 59 for the spectrum.  With smaller buffers (`latency :low`) vis draws as fast as the renderer goes.

A scope frame's 7 ms: about 1.5 ms decimating and rasterizing lines, 1.4 ms canvas conversion (Numo), 0.8 ms cell composition, 1.9 ms ANSI output.  Writing to a real terminal adds the terminal's own time (a 120x45 truecolor frame is 13-29 KB: scope waveform 27 KB, ascii 16 KB).  Static renders for the gallery (5 charts): text 25-115 ms per look, SVG 50-90 ms per theme, PNG ~200 ms per 720x380 image (the pixel renderer is too slow for 60 fps inline-image vis; live vis stays text).

## Live panes: fast_ui kernels and Plot::Live (ui-2 step 1, 2026-10-15)

The terminal UI (research-ui-2 d3e30356: in-process painter, native cell grid, snapshot-driven panes) needs plot panes that hold the GVL briefly and allocate little; the spike measured 1-1.6 ms per Plot frame on the 7950X.  The maintainer's bar: "a two-waveform gnuplot-based plot ... at over 90fps in Konsole. So let's get aggressive"; "If Braille slows us down with multibyte chars we can explore other options too."

**C kernels** (`ext/mb/sound/fast_ui`, `MB::Sound::FastUI`; every one an exact mirror of the Ruby, which stays as the reference: `Plot.native = false` or `MB_SOUND_PLOT=ruby`):
- `FastUI.decimate` (`Geometry.decimate_ruby`), `.polyline` (`Raster#polyline_ruby`: line_points + dash + set; lines over 4M dots go to Ruby, which subsamples), `.area` (`Text::Surface#area_ruby`), `.project` (`Mark::Base#device_ruby` for scales whose `forward` is Base's (linear) or Log's; `Scale#projection`), `.monotonic` (`Geometry.monotonic_ruby`).  Numo semantics copied: NaN-skipping min/max (numo `f_min`/`f_max`), numo's double to Int32 cast (through `long long` for negatives), C `round`.
- `FastUI::Grid` (since term-extract-1 a subclass of mb-term's `MB::Term::FastTerm::Grid`, which holds everything here but `#compose`; mirror `MB::Term::Cells`): cells as codepoint + fg/bg 0xRRGGBB (-1 none) + attributes; `#compose` (Canvas.cells + Panel#compose without a heatmap layer; canvases get codepoint tables from `Canvas::TABLES`), `#lines`/`#to_text` (SGR in every color mode; `index256` and the 16-color table ported exactly; a reused byte buffer and a 64-entry SGR cache), `#frame(prev, mode, row, col, sync)` (all cells or the cells that differ from `prev`, runs placed with CUP, gaps of up to 4 unchanged cells rewritten, DEC 2026 optional), `#write_frame(io, ...)` (encode + write(2) without the GVL; the buffer is reserved for the worst case first).  `Text::NativeCells < FastUI::Grid` has `MB::Term::Cells`' interface; `Cells` (the Ruby mirror) now stores colors packed as Integers and compares styles by value (identity before: equal colors from different Arrays emitted a redundant reset + SGR; no existing spec changed).
- `Text::Frame` draws in two steps, `Panel#layout` (title, legend, axes, labels, colorbar, grid lines into a Surface snapshot) and `Panel#paint` (marks + compose), and keeps the layout while `Panel.layout_key` (titles, legend entries, fitted scales' settings, heatmap scale/colormap) is unchanged.  Static cells are all outside the plot area, so drawing them before the marks gives the same text; `Text.render` uses a fresh Frame.
- `Plot::Live.new(width:, height:, look:, color:, theme:)`: `#redraw(chart)` (text, identical to `Text.render`), `#lines`, `#frame(chart, row:, col:, full:, sync:)` and `#write(io, chart, ...)` (only the cells that changed since the last frame; `#invalidate` after a clear), `#layouts`; `#draw(chart, grid, x:, y:)` blits the chart's cells into a screen's grid (`native:` picks NativeCells or Cells to match it): how the UI's scope and spectrum panes draw since ui-fix-3, so overlays painted later stay on top.
- Kept as built: for irregular x (log frequency) `decimate_ruby` keeps each group's first and last x even for text rasters (its `ends` variable is reassigned before the check); the C mirrors it.

**Measured** (`bin/plot_benchmark.rb --yjit both`, Mac container, i9-9880H, 300 frames per case, fresh data every frame, truecolor; ms median; before = master-ai 4f1ffe0d `Text.render`, after = `Live#redraw`; full table in the ui-2 report):

| pane | look | before off / on | after off / on | allocations | GC runs per 1000 frames |
|---|---|---|---|---|---|
| scope 60x16, 2 ch | scope | 1.86 / 1.45 | 0.21 / 0.16 | 4318 -> 236 | 70 -> 3 |
| scope 60x16 | blocks | 1.93 / 1.56 | 0.21 / 0.17 | 5317 -> 326 | 43 -> 3 |
| spectrum 120x30 (2048-point FFT included) | scope | 3.59 / 3.32 | 0.30 / 0.28 | 8400 -> 166 | 37 -> 3 |
| vis 120x45, 2 ch | scope | 4.96 / 3.59 | 0.35 / 0.35 | 10169 -> 236 | 60 -> 0 |
| vis 120x45 | blocks | 4.68 / 3.84 | 0.31 / 0.27 | 13293 -> 326 | 50 -> 0 |
| vis 120x45 | ascii | 2.70 / 2.24 | 0.23 / 0.19 | 7555 -> 236 | 33 -> 0 |

8-15x faster in every look and color mode, YJIT on or off; `MB_SOUND_PLOT=ruby` with `Text.render` measures 0.8-1.0x of master (the packed-color mirror is slightly slower), a fair stand-in for "before" where master isn't at hand (`bin/plot_benchmark_native.sh` uses it).  What is left per frame is mostly Ruby building the chart (preset, marks, scales fit: ~0.05-0.1 ms; the spectrum's FFT 0.08 ms), not drawing.  Budget: a scope plus a spectrum pane at 30 fps cost ~0.45 ms per 33 ms frame (1.4% of a core), each GVL hold one pane's draw (0.15-0.3 ms median, p99 0.4-0.8 ms; `write_frame` encodes and writes without the GVL), next to the spike's 0.26 ms p99 render-thread wait for native panes with `Thread.pass` between them.  A 120x45 two-channel vis at 90 fps: 0.35 ms x 90 = 3% of a core before the terminal.

**Terminal bytes per frame** (truecolor, DEC 2026 included): full redraws scope look 5.8 KB at 60x16, 22 KB at 120x45; changed cells 3.3 KB and 11.3 KB (waveforms move everywhere, so most cells change); blocks 15.5 KB changed of 20 KB at 120x45 (two colors per cell); ascii 2.6 KB of 5.7 KB; color mode none roughly halves it.  Braille is 3 bytes per cell, but the escapes dominate: at 120x45 a scope frame is 4.3 KB without color vs 11.3 KB truecolor.  The terminal's own parse and draw time can only be measured in a real terminal: `bin/plot_benchmark.rb --tty` (ends with a cursor position query the terminal must answer) and `bin/plot_benchmark_native.sh` for the maintainer's iTerm2/Konsole.  Inline images are no option for live panes yet: `to_png` at 480x256 takes ~310 ms.

## Open questions and later work

- Which looks and themes to keep as defaults (the gallery is for picking): `:scope` and `:paper`/`:studio` for now.
- Inline images and sextant glyphs are untested in the maintainer's iTerm2 and Konsole.

- Faster pixel rendering (for inline-image vis), interactive SVG crosshairs, a bitmap font with Braille for terminal screenshots (the gallery dev check synthesized glyphs).

## overlay and tables (ux-1, 2026-10-17)

Maintainer: "`overlay` is a pain to build hash of title to hash to etc".  `overlay a, b, c` (labels from named graphs or tones, else 1, 2, ...) and `overlay saw: a, square: b` draw one chart, titled with the labels joined by "vs" unless `title:`; curves are NArrays or number Arrays (x = 0, 1, ...), [xs, ys], [x, y] pairs, or graphs and tones (`samples:`).  `overlay_chart` returns the chart; `overlay chart1, chart2` puts charts side by side (hist's density plots, bin/plot_noise.rb).  Tables print through `MB::Sound::Table` (lib/mb/sound/table.rb): theme colors, numbers aligned on the decimal point, box rules (ASCII with `UI.glyphs :ascii`), plain without a terminal or with NO_COLOR.

