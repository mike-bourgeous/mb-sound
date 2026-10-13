# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kaede_tape",
  kind: :effect,
  saved: "2026-10-13T09:31:44Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kaede_rowntree.rb"
inputs :input
param :wear, 0.3, range: 0.0..1.0, description: "Tape wear 0..1"

input.delay(0.37.hz.lfo.sine.at(0.006..0.009) + 1.3.hz.lfo.square.sample_hold.smooth(0.7692307692307692).at(-0.0007..0.0007)).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6).decimate(16000 - wear * 11000, mix: wear * 0.6)
