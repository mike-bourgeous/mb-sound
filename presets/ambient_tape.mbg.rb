# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "ambient_tape",
  kind: :effect,
  saved: "2026-10-15T05:40:02Z",
  mb_sound: "0.12.0.usegit (a25e25a0)",
  from: "bin/synths/ambient.rb",
  description: "Effect :ambient_tape from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen)."
inputs :input
param :wear, 0.3, range: 0.0..1.0, description: "Tape wear 0..1"

sig = drift(1.3, range: -0.0007..0.0007, smooth: :smoothstep, from: 0.0)
osc = noise.at(0.0009765625)
(input.delay(0.37.hz.lfo.sine.at(0.006..0.009) + sig) + osc).quantize(0.001953125).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
