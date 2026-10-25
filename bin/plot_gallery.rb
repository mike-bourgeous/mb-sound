#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Renders every plot look and theme of MB::Sound::Plot on the same sounds.
#
# Writes a self-contained HTML gallery (terminal captures converted from
# ANSI, inline SVGs, PNGs) plus the raw .ans captures and .svg files to the
# output directory, or prints one look in the terminal with --show.
#
# Usage: $0 [-o DIR] [--show LOOK] [--width COLS] [--height ROWS]
#
# Try:
#     bin/plot_gallery.rb --show scope     # Braille lines in your terminal
#     bin/plot_gallery.rb --show blocks    # half-block fills and heatmaps
#     bin/plot_gallery.rb -o tmp/plot-gallery && open tmp/plot-gallery/index.html

require 'bundler/setup'
require 'fileutils'
require 'mb-sound'

# The sounds every variation draws: a 2-second A minor 7 saw arpeggio with
# a rising sine sweep under it, one note's spectrum, an ADSR, and one cycle
# of four basic waveforms.
def gallery_charts(compact: false)
  plot = MB::Sound::Plot
  rate = 48000
  notes = [45, 48, 52, 55, 57, 55, 52, 48] # A2 C3 E3 G3 A3 G3 E3 C3
  len = rate / 4
  t = Numo::DFloat.new(len).seq / rate
  decay = Numo::NMath.exp(-t / 0.09) * 0.8
  arp = Numo::DFloat.zeros(0).concatenate(*notes.map { |n|
    (440 * 2**((n - 69) / 12.0)).hz.ramp.sample(len).then { |s| Numo::DFloat.cast(s) * decay }
  })
  total = arp.length
  tt = Numo::DFloat.new(total).seq / rate
  phase = 150 * 2.0 / Math.log(40) * (Numo::NMath.exp(tt / 2.0 * Math.log(40)) - 1) # 150 Hz to 6 kHz
  sweep = Numo::NMath.sin(phase * 2 * Math::PI) * 0.12
  mix = arp + sweep

  env = MB::Sound::Envelope.preset(:adsr, attack: 0.02, decay: 0.15, sustain: 0.6, release: 0.4, hold: 0.5)
  env_data = Numo::DFloat.zeros(0).concatenate(*Array.new(100) { Numo::DFloat.cast(env.sample(480)) })

  cycle = Numo::DFloat.linspace(0, 1, 801)[0...800]
  shapes = %i[sine triangle square ramp].to_h { |w|
    [w.to_s, Numo::DFloat.cast(cycle.to_a.map { |v| MB::Sound::Tone.value_at(w, v).real })]
  }

  if compact
    return {
      waveform: [plot.waveform(mix, title: 'A minor 7 arpeggio + sweep'), 'MB::Sound::Plot.waveform(sound)'],
      spectrum: [plot.spectrum(arp[0...8192], title: 'Saw at A2'), 'MB::Sound::Plot.spectrum(sound[0...8192])'],
      spectrogram: [
        plot.spectrogram(mix, title: 'Spectrogram', fft: 1024, hop: 512), 'MB::Sound::Plot.spectrogram(sound, fft: 1024, hop: 512)',
        # Terminal captures with 16 colors instead of 64 (fewer style classes)
        plot.spectrogram(mix, title: 'Spectrogram', fft: 1024, hop: 512, colormap: MB::Sound::Plot::Colormap.new(:magma, size: 16)),
      ],
    }
  end

  {
    waveform: [
      plot.waveform(mix, title: 'A minor 7 arpeggio + sweep'),
      'MB::Sound::Plot.waveform(sound)',
    ],
    spectrum: [
      plot.spectrum(arp[0...8192], title: 'Saw at A2'),
      'MB::Sound::Plot.spectrum(sound[0...8192])',
    ],
    spectrogram: [
      plot.spectrogram(mix, title: 'Spectrogram', fft: 2048, hop: 256),
      'MB::Sound::Plot.spectrogram(sound, fft: 2048, hop: 256)',
    ],
    envelope: [
      plot.envelope(env_data, title: 'ADSR (analog curves)'),
      'MB::Sound::Plot.envelope(adsr.sample(48000))',
    ],
    series: [
      plot.chart(title: 'One cycle') {
        x :linear, 0..1, label: 'phase', unit: 'cycles'
        y :symmetric, label: 'amplitude'
        shapes.each { |name, d| line d, x: 0..1, label: name }
      },
      "MB::Sound::Plot.chart(title: 'One cycle') {\n  x :linear, 0..1, label: 'phase', unit: 'cycles'\n  y :symmetric\n  shapes.each { |name, d| line d, x: 0..1, label: name }\n}",
    ],
  }
end

LOOK_NOTES = {
  scope: 'Braille lines (2x4 dots per cell) with box axes and a dotted grid.  Densest lines; one color per cell.',
  blocks: 'Half blocks: two true-color pixels per cell, lines filled to zero.  Best for heatmaps and fills.',
  mosaic: 'Sextants (2x3 per cell, two colors per cell), labels without axis lines.  Needs a font with Unicode 13 "Symbols for Legacy Computing".',
  quad: 'Quadrants (2x2 per cell, two colors) with box axes: blockier than sextants, supported by every font.',
  spark: 'Eighth blocks (1x8 per cell) filled from zero, no axes: compact sparkline panels.',
  ascii: 'Plain ASCII, no color: the fallback for any terminal, log, or spec.',
}.freeze

THEME_NOTES = {
  paper: 'Light paper with a serif face.',
  studio: 'Dark studio console.',
  phosphor: 'Oscilloscope phosphor with glow.',
}.freeze

def esc(s)
  MB::Sound::Plot::AnsiHtml.escape(s)
end

# Style classes shared by every terminal capture (AnsiHtml.convert)
CLASSES = {}

def gallery_page(sections, compact: false)
  sounds = compact ? 'a two-second A minor 7 saw arpeggio over a sine sweep from 150 Hz to 6 kHz, one note\'s spectrum on a log frequency axis with note names, and the spectrogram (this is the compact gallery; bin/plot_gallery.rb without --compact adds an ADSR envelope and a multi-series chart with a legend at larger sizes)' : 'a two-second A minor 7 saw arpeggio over a sine sweep from 150 Hz to 6 kHz, one note\'s spectrum on a log frequency axis with note names, its spectrogram, an ADSR envelope, and four waveforms with a legend'
  body = sections.map { |s| section_html(s) }.join("\n")
  <<~HTML
    <title>mb-sound Plot Gallery</title>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600&family=IBM+Plex+Sans:wght@400;600&display=swap">
    <style>
    /* Layout: a lab notebook of specimens; each variation is a section of captures in a responsive grid. */
    :root {
      --bg: #f3f2ee; --fg: #1d1c1a; --muted: #5d5b55; --rule: #d9d6cc; --accent: #2a78d6;
      --term-bg: #141413; --term-fg: #d8d8d2;
      --display: 'Fraunces', 'Iowan Old Style', Georgia, serif;
      --body: 'IBM Plex Sans', 'Helvetica Neue', Arial, sans-serif;
      --mono: 'DejaVu Sans Mono', 'Menlo', 'Cascadia Mono', 'Consolas', ui-monospace, monospace;
      color-scheme: light;
    }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #191918; --fg: #ecebe6; --muted: #a9a79f; --rule: #34332f; --accent: #5598e7; color-scheme: dark } }
    :root[data-theme="dark"] { --bg: #191918; --fg: #ecebe6; --muted: #a9a79f; --rule: #34332f; --accent: #5598e7; color-scheme: dark }
    body { background: var(--bg); color: var(--fg); font: 15px/1.5 var(--body); }
    main { max-width: 1500px; margin: 0 auto; padding-inline: 20px; padding-block: 28px 64px; display: grid; gap: 40px; }
    h1 { font: 600 2.1rem/1.15 var(--display); margin: 0; text-wrap: balance; }
    h2 { font: 600 1.4rem/1.2 var(--display); margin: 0; text-wrap: balance; }
    h3 { font: 600 0.8rem/1.3 var(--body); margin: 0; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
    p { margin: 0; max-width: 70ch; }
    header { display: grid; gap: 10px; }
    section { display: grid; gap: 16px; border-top: 1px solid var(--rule); padding-top: 24px; }
    .grid { display: grid; gap: 22px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 640px), 1fr)); }
    figure { margin: 0; display: grid; gap: 8px; min-width: 0; }
    .term { background: var(--term-bg); color: var(--term-fg); border-radius: 6px; overflow-x: auto; }
    .term pre { margin: 0; padding: 12px 14px; font: 12px/1.17 var(--mono); }
    .term pre i { font-style: normal; display: inline-block; width: 1ch; overflow: hidden; vertical-align: top; text-align: center; }
    .img { overflow-x: auto; border-radius: 6px; }
    .img svg, .img img { display: block; max-width: 100%; height: auto; }
    code { font: 12.5px/1.45 var(--mono); }
    figcaption { display: grid; gap: 4px; min-width: 0; }
    figcaption code { white-space: pre-wrap; color: var(--muted); }
    .note { color: var(--muted); }
    nav { display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 0.9rem; }
    nav a { color: var(--accent); }
    #{MB::Sound::Plot::AnsiHtml.stylesheet(CLASSES, scope: '.term')}
    </style>
    <main>
    <header>
      <h1>mb-sound Plot Gallery</h1>
      <p>Every look of <code>MB::Sound::Plot</code> on the same sounds: #{sounds}.  Terminal captures are the renderer's ANSI output converted to HTML (raw <code>.ans</code> files are next to this page; <code>cat</code> them in a true-color terminal).  Image themes are SVG drawn by the same layout; the last section is the pixel renderer used for PNG files and sixel, kitty, and iTerm2 inline images.</p>
      <nav>#{sections.map { |s| %(<a href="##{s[:id]}">#{esc(s[:name])}</a>) }.join}</nav>
    </header>
    #{body}
    </main>
  HTML
end

def section_html(s)
  figures = s[:items].map { |item|
    body =
      case item[:kind]
      when :ansi then %(<div class="term"><pre>#{MB::Sound::Plot::AnsiHtml.convert(item[:content], cells: true, classes: CLASSES)}</pre></div>)
      when :svg then %(<div class="img">#{item[:content].sub(/\A<svg /, '<svg role="img" ')}</div>)
      when :png then %(<div class="img"><img alt="#{esc(item[:title])}" src="data:image/png;base64,#{[item[:content]].pack('m0')}"></div>)
      end
    %(<figure>#{body}<figcaption><h3>#{esc(item[:title])}</h3><code>#{esc(item[:call])}</code></figcaption></figure>)
  }
  <<~HTML
    <section id="#{s[:id]}">
      <h2>#{esc(s[:name])}</h2>
      <p class="note">#{esc(s[:note])}</p>
      <div class="grid">#{figures.join}</div>
    </section>
  HTML
end

MB::Sound.script(
  output: [nil, '-o', String, 'Output directory (default tmp/plot-gallery, or tmp/plot-gallery-compact with --compact)'],
  compact: [false, '-c', 'A small gallery (three sounds, 60x16 captures, small SVGs, one small PNG)'],
  show: [nil, '-s', String, "Print one look in the terminal instead (#{LOOK_NOTES.keys.join(', ')})"],
  width: [100, '-W', Integer, 'Terminal capture width in columns', 40..400],
  height: [22, '-H', Integer, 'Terminal capture height in lines', 8..200],
  svg_width: [720, Integer, 'SVG and PNG width in pixels', 200..4000],
  svg_height: [380, Integer, 'SVG and PNG height in pixels', 120..4000],
) { |_, p|
  charts = gallery_charts(compact: p.compact)
  width, height, svg_width, svg_height = p.width, p.height, p.svg_width, p.svg_height
  if p.compact
    width = 60 if width == 100
    height = 16 if height == 22
    svg_width = 400 if svg_width == 720
    svg_height = 230 if svg_height == 380
  end
  heatmap = p.compact ? [96, 48] : [600, 300]

  if p.show
    look = p.show.to_sym
    abort "Unknown look #{p.show} (#{LOOK_NOTES.keys.join(', ')})" unless LOOK_NOTES.key?(look)

    charts.each_value { |chart, _| puts chart.to_s(width: width, height: height, look: look), '' }
    next
  end

  dir = p.output || (p.compact ? 'tmp/plot-gallery-compact' : 'tmp/plot-gallery')
  FileUtils.mkdir_p(dir)
  sections = []
  timings = Hash.new(0.0)

  LOOK_NOTES.each do |look, note|
    items = charts.map { |name, (chart, call, text_chart)|
      t = MB::U.clock_now
      text = (text_chart || chart).to_s(width: width, height: height, look: look, color: look == :ascii ? :none : :truecolor)
      timings["text #{look}"] += MB::U.clock_now - t
      File.write(File.join(dir, "#{look}_#{name}.ans"), text + "\n")
      { kind: :ansi, title: name.to_s, content: text, call: "#{call}.to_s(look: :#{look})" }
    }
    sections << { id: "look-#{look}", name: "Terminal: #{look}", note: note, items: items }
  end

  THEME_NOTES.each do |theme, note|
    items = charts.map { |name, (chart, call)|
      t = MB::U.clock_now
      svg = chart.to_svg(width: svg_width, height: svg_height, theme: theme, heatmap_pixels: heatmap)
      timings["svg #{theme}"] += MB::U.clock_now - t
      File.write(File.join(dir, "#{theme}_#{name}.svg"), svg)
      { kind: :svg, title: name.to_s, content: svg, call: "#{call}.save('#{name}.svg', theme: :#{theme})" }
    }
    sections << { id: "svg-#{theme}", name: "SVG: #{theme}", note: note, items: items }
  end

  png_charts = p.compact ? charts.first(1) : charts
  items = png_charts.map { |name, (chart, call)|
    t = MB::U.clock_now
    png = p.compact ? chart.to_png(width: 360, height: 200, theme: :studio) : chart.to_png(width: svg_width, height: svg_height, theme: :studio)
    timings['png studio'] += MB::U.clock_now - t
    { kind: :png, title: name.to_s, content: png, call: "#{call}.save('#{name}.png')  # or .show(image: true)" }
  }
  sections << { id: 'png', name: 'Pixels: PNG and inline images', note: 'The pure-Ruby pixel renderer (antialiased lines, DejaVu Sans Mono bitmap font) behind PNG files and sixel, kitty, and iTerm2 inline terminal images.', items: items }

  html = gallery_page(sections, compact: p.compact)
  File.write(File.join(dir, 'index.html'), html)
  puts "Wrote #{File.join(dir, 'index.html')} (#{(html.bytesize / 1024.0).round} KB)"
  timings.each { |k, v| puts format('%-16s %7.1f ms for %d charts', k, v * 1000, k.start_with?('png') ? png_charts.length : charts.length) }
}
