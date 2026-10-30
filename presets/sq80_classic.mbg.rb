# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "sq80_classic",
  kind: :synth,
  saved: "2026-10-30T04:12:11Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :classic: The voice as first built (bin/synths/sq80_voice.rb), an octave down: a formant wave, a SYNTH 3-style wave a few cents up, and a blipped PRIME an octave below them into a driven four-pole; 32nd-note filter chop and poly pressure flutter. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :classic, voices: nil, drive_mode: nil, drive: nil, second_release: false }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(500.0), description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, (0.0..1.0).at(0.4), description: "Resonance 0..1, CC 71 moves it (classic 0.4)"
param :chop, (0.0..6.0).at(1.5), description: "Looping chop envelope depth in octaves, 0: off (classic 1.5)"
param :flutter, (0.0..4.0).at(1.0), description: "Poly pressure flutter depth in octaves, 0: off (classic 1.0)"

sq80(midi, :classic, cutoff: cutoff, reso: reso, chop: chop, flutter: flutter, seed: drawn_seed(900450186894289455))
