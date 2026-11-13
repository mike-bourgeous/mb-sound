# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "noise_bands",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Noise-band pad: white noise through bandpasses at the note's first twelve harmonics (levels falling with the harmonic), pitched when the bands are narrow and airy when they are wide (noise-band harmonics; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:noise, :bandpass, :harmonics, :pad, :airy],
  options: { patch: :noise_bands }
inputs midi: :notes
param :focus, (2.0..400.0).at(40.0), description: "Band Q: higher is narrower and more pitched"
param :stretch, (0.5..2.0).at(1.0), description: "Spacing of the bands in harmonics (1: harmonic; others: inharmonic)"
param :attack, (0.001..8.0).at(0.5), description: "Attack in seconds"
param :release, (0.01..8.0).at(1.2), description: "Release in seconds"

synth(midi, voices: 6) { |v|
  noise.bandpass_series(v.freq, count: 12, ratio: stretch, quality: focus, gain: ->(i) { 1.0 / (i + 1) }) * focus ** 0.5 * v.env(attack, 0.5, 0.9, release, gm: false) * 0.85
}
