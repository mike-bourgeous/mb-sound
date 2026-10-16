# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "ambient_koto",
  kind: :synth,
  saved: "2026-10-16T14:11:20Z",
  mb_sound: "0.12.0.usegit (f4cd275c)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :koto from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :koto, tune: -7.0, spread: 0.7 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"
param :wear, 0.6, range: 0.0..1.0, description: "Tape wear 0..1 (koto, harp): 12 bits of grain at 0, 10 at 0.6, 7 at 1"

voice = synth(midi, voices: 4) { |v|
  sig = v.hz
  body = sig.transpose(0).sine.at(0.9) * v.env(0.002, 1.8, 0.15, 1.5, gm: false)
  tine = sig.transpose(33.68825906469125).sine.at(0.25) * v.env(0.001, 0.25, 0, 0.2, gm: false)
  sig.pm(body + tine) * v.env(0.004, 3.2, 0.0, 1.6, gm: false) * (v.velocity * 0.5 + 0.5)
}
sig = (voice * 0.11).pan(-0.15)
sig2 = sig.and_then(silence(12)) + sig.reverb(room_size: 0.7, decay: 6, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
sig3 = drift(1.3, range: -0.0007..0.0007, smooth: :smoothstep, from: 0.0, seed: drawn_seed(3969543146641149120))
fx = wear.aease(->(t) { (2**((5 * t + 25 * t * t) / 6.0) - 1) / 31.0 }, out: 0.00048828125..0.015625)
sig4 = sig2.sounding(hold: 1, fade: 0.3)
osc = noise(seed: drawn_seed(1895649597198586619)).at(fx * 0.5)
osc2 = noise(seed: drawn_seed(827948490035658087)).at(fx * 0.5)
osc3 = noise(seed: drawn_seed(3203365596207111891)).at(fx * 0.5)
osc4 = noise(seed: drawn_seed(2691271404617651954)).at(fx * 0.5)
(sig2.delay(0.37.hz.lfo.sine.at(0.006..0.009) + sig3) + channels((osc + osc2) * sig4, (osc3 + osc4) * sig4)).quantize(fx).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6)
