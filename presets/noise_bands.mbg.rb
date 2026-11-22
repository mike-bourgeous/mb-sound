# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "noise_bands",
  kind: :synth,
  saved: "2026-11-14T18:32:02Z",
  mb_sound: "0.12.0.usegit (fc9fdbd)",
  from: "bin/synths/library_voices.rb",
  description: "Noise-band pad: white noise through narrow bandpasses at the note's first twelve harmonics (levels falling with the harmonic), each band wider than the one below; pitched when narrow, airy when wide (noise-band harmonics; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:noise, :bandpass, :harmonics, :pad, :airy],
  options: { patch: :noise_bands }
inputs midi: :notes
param :width, (1.0..200.0).at(6.0), description: "Width of the lowest band in cents (narrow: pitched; wide: airy)"
param :flare, (1.0..10.0).at(4.0), description: "The top band's width over the lowest's (the widths grow evenly in ratio)"
param :stretch, (0.5..2.0).at(1.0), description: "Spacing of the bands in harmonics (1: harmonic; others: inharmonic)"
param :rolloff, (0.0..4.0).at(1.5), description: "How fast the bands fade up the series: band n's level is 1 / n ** rolloff (higher: darker; 1 falls 6 dB per octave)"
param :attack, (0.001..8.0).at(0.5), description: "Attack in seconds"
param :release, (0.01..8.0).at(1.2), description: "Release in seconds"

synth(midi, voices: 6) { |v|
  noise.bandpass_series(v.freq, count: 12, ratio: stretch, quality: [1731.2340490667561 / (width * flare ** 0.0), 1731.2340490667561 / (width * flare ** 0.09090909090909091), 1731.2340490667561 / (width * flare ** 0.18181818181818182), 1731.2340490667561 / (width * flare ** 0.2727272727272727), 1731.2340490667561 / (width * flare ** 0.36363636363636365), 1731.2340490667561 / (width * flare ** 0.45454545454545453), 1731.2340490667561 / (width * flare ** 0.5454545454545454), 1731.2340490667561 / (width * flare ** 0.6363636363636364), 1731.2340490667561 / (width * flare ** 0.7272727272727273), 1731.2340490667561 / (width * flare ** 0.8181818181818182), 1731.2340490667561 / (width * flare ** 0.9090909090909091), 1731.2340490667561 / (width * flare ** 1.0)], gain: [1.0, 0.5 ** rolloff, 0.3333333333333333 ** rolloff, 0.25 ** rolloff, 0.2 ** rolloff, 0.16666666666666666 ** rolloff, 0.14285714285714285 ** rolloff, 0.125 ** rolloff, 0.1111111111111111 ** rolloff, 0.1 ** rolloff, 0.09090909090909091 ** rolloff, 0.08333333333333333 ** rolloff], normalize: true) * v.env(attack, 0.5, 0.9, release, gm: false) * 0.834
}
