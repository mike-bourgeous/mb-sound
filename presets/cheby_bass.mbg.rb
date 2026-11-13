# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "cheby_bass",
  kind: :synth,
  saved: "2026-11-13T02:06:34Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Waveshaped bass: a sine through Chebyshev polynomials driven harder at the start of each note, so the upper harmonics follow the note's envelope (waveshaping synthesis) (waveshaping (Chebyshev); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:waveshaping, :chebyshev, :bass],
  options: { patch: :cheby_bass }
inputs midi: :notes
param :drive, (0.0..1.5).at(1.0), description: "Drive at the strike (brightness; past 1 the curve's ends clip)"
param :hold, (0.0..1.0).at(0.4), description: "Drive kept while the note holds, as a share of the strike's"
param :ddecay, (0.01..5.0).at(0.3), description: "Seconds the drive takes to fall to its held share"
param :release, (0.005..2.0).at(0.08), description: "Release in seconds"

synth(midi, voices: 2) { |v|
  v.hz.sine.chebyshev(h1: 1, h2: 0.5, h3: -0.35, h4: -0.2, h5: 0.2, h6: 0.1, h7: -0.1, drive: drive * (hold + (1 - hold) * v.env(0.001, ddecay, 0, release, gm: false).no_velocity)) * v.env(0.002, 0.5, 0.9, release, gm: false) * 0.5
}.hp1(20)
