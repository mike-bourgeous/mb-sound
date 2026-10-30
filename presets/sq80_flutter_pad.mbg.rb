# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "sq80_flutter_pad",
  kind: :synth,
  saved: "2026-10-30T04:12:18Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :flutter_pad: A slow pad: no chop, deep per-key pressure flutter (press one finger harder than the others), a long second-release tail. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :flutter_pad, voices: nil, drive_mode: nil, drive: nil, chop: nil, second_release: false }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(650.0), description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, (0.0..1.0).at(0.3), description: "Resonance 0..1, CC 71 moves it (classic 0.4)"
param :flutter, (0.0..4.0).at(2.5), description: "Poly pressure flutter depth in octaves, 0: off (classic 1.0)"

sq80(midi, :flutter_pad, cutoff: cutoff, reso: reso, flutter: flutter, seed: drawn_seed(900450186894289455))
