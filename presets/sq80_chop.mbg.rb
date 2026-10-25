# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "sq80_chop",
  kind: :synth,
  saved: "2026-10-24T18:50:09Z",
  mb_sound: "0.12.0.usegit (97de948a)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :chop: Rhythm from the chop envelope: a dark, resonant filter opened in 32nd notes while keys are held, restarting with each note, so chords stagger. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :chop, voices: nil, drive_mode: nil, drive: nil, flutter: nil, second_release: false }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(260.0), description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, (0.0..1.0).at(0.65), description: "Resonance 0..1, CC 71 moves it (classic 0.4)"
param :chop, (0.0..6.0).at(3.0), description: "Looping chop envelope depth in octaves, 0: off (classic 1.5)"

sq80(midi, :chop, cutoff: cutoff, reso: reso, chop: chop, seed: drawn_seed(900450186894289455))
