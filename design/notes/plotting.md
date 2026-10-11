# Plotting

`MB::Sound::Plot` (`lib/mb/sound/plot.rb`, `lib/mb/sound/plot/`) draws every plot in mb-sound in pure Ruby, from Numo arrays, with no external process.  Built 2026-10-11 on branch `plot-1` after a gnuplot output race made `plot_methods_spec.rb:169` flaky (gnuplot's end-marker echo leaked into captured output); the maintainer asked to "bump up the priority of our custom plotting code and remove gnuplot usage", with "a few variations" and "a good architecture for scales axes legends etc."  mb-math's gnuplot pipe (`MB::M::Plot`) is untouched but no longer used by mb-sound; `spec/support/no_gnuplot.rb` fails any spec that starts it.  No gnuplot fallback was kept: PlotMethods builds charts directly now, so a fallback could only have covered the old Hash interface (a `plotter` override with MB::M::Plot's `#plot` still works for the Hash-based methods).

## Layers

A small grammar of graphics, all plain Ruby objects:

- **Scales** (`plot/scale.rb`): map data to 0..1 and make ticks (`Tick` = value, label, major).  `Linear` (nice domains when fit), `Symmetric` (waveforms, -m..m), `DB` (floor -120 so silence fits; fitted domains never go below the floor), `Log`, `Frequency` (log Hz labeled 100, 1k, 10k, plus secondary note-name ticks for every C, every other C past 9 octaves, or every `notes: n` semitones, at `a4:` tuning), `Time` (data in seconds, or in samples with `sample_rate:`; labels in s/ms/µs from the domain's size; `unit: :samples`; `unit: :bars` with beats), `Categorical`.  A scale without a domain is fit to the chart's data (`#fit`); scales are immutable.  `Scale.build` takes a Scale, a Range (linear domain), or a kind Symbol plus keywords (the builder's `x`/`y`).
- **Format** (`plot/format.rb`): nice steps (1, 2, 5 x 10^k), shared decimals per axis, SI prefixes (`si: true` both ways, `:up` only k/M/G), no negative zero, bare "0" on prefixed axes.
- **Coords** (`plot/coord.rb`): `Cartesian`, `Polar` (x is the angle in turns of its domain, y the radius; text panels keep it square, rings and spokes instead of axes).
- **Marks** (`plot/mark.rb`): `Line` (`step: true` staircase), `Area` (filled to `base:`), `Points`, `Stems`, `Band` (between two lines), `Rule` (reference line, muted), `Heatmap` (rows bottom to top, `x:`/`y:` Ranges, `z_scale:` (e.g. `Scale::DB`), `colormap:`; sampled through the scales' `invert`, so a log frequency axis over linear FFT bins just works).  Marks draw through a small surface protocol (polyline with NaN gaps, points, area, band, image grid) that each renderer implements.
- **Decimation** (`Geometry.decimate` in `plot/raster.rb`): lines with more than two points per device column become each column's min and max, in the order the signal crossed them.  Text rasters put both at the rounded column (groups a little under a column apart, so no column is skipped); vector output puts them at each group's first and last x (smooth steep slopes).  Evenly spaced x (index or Range) decimates fully vectorized; other monotonic x (log frequency) loops over columns.
- **Guides**: drawn by the renderers from the scales and marks: title row with the y axis title and the legend (right-aligned; entries that don't fit are dropped; shown for two or more labeled series, or one without a title, or with `legend: true`), y tick labels, x axis with tick marks, x tick labels with the x axis title (with its unit) taking precedence at the right, a note-name row for frequency axes, a colorbar for heatmaps.
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
- **Image** (`plot/image.rb`): a Float RGB buffer; antialiased lines by splatting samples every 0.25 px with bilinear weights through `bincount`; fills through the same Raster column fills; text from a DejaVu Sans Mono 12 px bitmap font (8x16 cells, 4-bit alpha, ASCII plus µ · …) generated by `lib/mb/sound/plot/make_font.rb` with ffmpeg's drawtext (Bitstream Vera license allows derivatives); PNG encoded with Zlib (standard library).  Chosen over ffmpeg for PNG because images then need no process, render the same everywhere (ffmpeg's SVG decoder needs librsvg, which the Mac's Homebrew ffmpeg may lack), and the same pixels feed the inline terminal protocols.  Sixel quantizes to 6x7x6 levels.

Themes (`plot/theme.rb`): categorical palettes from the data-viz reference palette (validated for color vision deficiencies in this order; light steps for light surfaces, dark steps for dark, and brighter steps for thin terminal glyphs on dark terminals); colormaps `:magma` (text and paper), `:inferno` (studio), `:viridis`, `:blues`, `:phosphor`, `:gray` (64 steps, from ninths of matplotlib's maps).  Image themes `:paper` (light, serif), `:studio` (dark), `:phosphor` (oscilloscope green with glow); terminal themes `:dark`, `:light`.

## mb-sound integration

- `PlotMethods#plotter` returns `Plot::Plotter`, an MB::M::Plot-compatible facade: `plot(Hash, rows:, columns:, print:)` (data arrays, `[x, y]` pairs, 2D arrays as heatmaps; `:xrange`, `:yrange`, `:logscale`, `:type` ('lines', 'points', 'steps', 'impulses', 'boxes', 'filledcurves'), `:x`, `:x_label`), `xrange`, `yrange`, `logscale`, `print`, `width`, `height` (live from the terminal unless fixed), `save_image`, `close`, plus `draw(chart_or_figure)`.  `command` raises (no gnuplot).  Graphical plotters show inline images where detected, else text at the terminal's size.
- `plot`, `spectrum`, `time_freq`, `mag_phase`, `hist` keep their signatures and Hash-based panels (x is the sample or bin index, as before); `overlay` (and `hist(density:/pdf:)`) builds a Figure with legends; new `chart`, `figure`, `spectrogram(sound, seconds:, fft:, hop:, floor:, log:, colormap:)`.
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

## Open questions and later work

- Which looks and themes to keep as defaults (the gallery is for picking): `:scope` and `:paper`/`:studio` for now.
- Inline images and sextant glyphs are untested in the maintainer's iTerm2 and Konsole.
- `plot(..., spectrum: true)` and `time_freq`/`mag_phase` still use bin indexes on the x axis (as with gnuplot); they could move to `Plot.spectrum`'s Hz axis.
- Faster pixel rendering (for inline-image vis), interactive SVG crosshairs, a bitmap font with Braille for terminal screenshots (the gallery dev check synthesized glyphs).
