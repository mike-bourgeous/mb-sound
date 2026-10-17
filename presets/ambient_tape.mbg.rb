# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "ambient_tape",
  kind: :effect,
  saved: "2026-10-17T17:19:19Z",
  mb_sound: "0.12.0.usegit (47598381)",
  from: "bin/synths/ambient.rb",
  description: "Effect :ambient_tape from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen)."
inputs input: :audio
param :wear, 0.6, range: 0.0..1.0, description: "Tape wear 0..1"

sig = drift(1.3, range: -0.0007..0.0007, smooth: :smoothstep, from: 0.0)
fx = wear.aease(->(t) { (2**((5 * t + 25 * t * t) / 6.0) - 1) / 31.0 }, out: 0.00048828125..0.015625)
osc = noise.at(fx * 0.5)
osc2 = noise.at(fx * 0.5)
(input.delay(0.37.hz.lfo.sine.at(0.006..0.009) + sig) + (osc + osc2) * input.sounding(hold: 1, fade: 0.3)).ring(:first).quantize(fx).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
