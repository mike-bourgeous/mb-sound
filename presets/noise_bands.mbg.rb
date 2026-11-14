# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "noise_bands",
  kind: :synth,
  saved: "2026-11-13T06:46:33Z",
  mb_sound: "0.12.0.usegit (366bde7)",
  from: "bin/synths/library_voices.rb",
  description: "Noise-band pad: white noise through narrow bandpasses at the note's first twelve harmonics (levels falling with the harmonic), each band wider than the one below; pitched when narrow, airy when wide (noise-band harmonics; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:noise, :bandpass, :harmonics, :pad, :airy],
  options: { patch: :noise_bands }
inputs midi: :notes
param :width, (1.0..200.0).at(6.0), description: "Width of the lowest band in cents (narrow: pitched; wide: airy)"
param :flare, (1.0..10.0).at(4.0), description: "The top band's width over the lowest's (the widths grow evenly in ratio)"
param :stretch, (0.5..2.0).at(1.0), description: "Spacing of the bands in harmonics (1: harmonic; others: inharmonic)"
param :attack, (0.001..8.0).at(0.5), description: "Attack in seconds"
param :release, (0.01..8.0).at(1.2), description: "Release in seconds"

synth(midi, voices: 6) { |v|
  noise.bandpass_series(v.freq, count: 12, ratio: stretch, quality: [1731.2340490667561 / (width * flare ** 0.0), 1731.2340490667561 / (width * flare ** 0.09090909090909091), 1731.2340490667561 / (width * flare ** 0.18181818181818182), 1731.2340490667561 / (width * flare ** 0.2727272727272727), 1731.2340490667561 / (width * flare ** 0.36363636363636365), 1731.2340490667561 / (width * flare ** 0.45454545454545453), 1731.2340490667561 / (width * flare ** 0.5454545454545454), 1731.2340490667561 / (width * flare ** 0.6363636363636364), 1731.2340490667561 / (width * flare ** 0.7272727272727273), 1731.2340490667561 / (width * flare ** 0.8181818181818182), 1731.2340490667561 / (width * flare ** 0.9090909090909091), 1731.2340490667561 / (width * flare ** 1.0)], gain: [1.0, 0.5, 0.3333, 0.25, 0.2, 0.1667, 0.1429, 0.125, 0.1111, 0.1, 0.0909, 0.0833], normalize: true) * v.env(attack, 0.5, 0.9, release, gm: false) * 0.52
}
