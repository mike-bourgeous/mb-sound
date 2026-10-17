# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "sq80_glass",
  kind: :synth,
  saved: "2026-10-17T17:19:19Z",
  mb_sound: "0.12.0.usegit (47598381)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :glass: Glassy keys: SYNTH 3 an octave up over a little formant and the PRIME blip, decaying to nothing with a second-release tail. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :glass, voices: nil, drive_mode: nil, drive: nil, chop: nil, second_release: false }
inputs midi: :notes
param :cutoff, 1800.0, range: 20..10000, description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, 0.2, range: 0.0..1.0, description: "Resonance 0..1, CC 71 moves it (classic 0.4)"
param :flutter, 1.5, range: 0.0..4.0, description: "Poly pressure flutter depth in octaves, 0: off (classic 1.0)"

sq80(midi, :glass, cutoff: cutoff, reso: reso, flutter: flutter, seed: drawn_seed(900450186894289455))
