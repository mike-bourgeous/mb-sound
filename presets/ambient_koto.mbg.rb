# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "ambient_koto",
  kind: :synth,
  saved: "2026-10-14T03:17:37Z",
  mb_sound: "0.12.0.usegit (796a1077)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :koto from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :koto, tune: -7.0, spread: 0.7 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"
param :wear, 0.0, range: 0.0..1.0, description: "Tape wear 0..1 (koto, harp)"

voice = synth(midi, voices: 4) { |v|
  sig = v.hz
  body = sig.transpose(0).sine.at(0.9) * v.env(0.002, 1.8, 0.15, 1.5, gm: false)
  tine = sig.transpose(33.68825906469125).sine.at(0.25) * v.env(0.001, 0.25, 0, 0.2, gm: false)
  sig.pm(body + tine) * v.env(0.004, 3.2, 0.0, 1.6, gm: false) * (v.velocity * 0.5 + 0.5)
}
sig = 1.3.hz.lfo.square.sample_hold(seed: drawn_seed(3969543146641149120))
sig2 = (voice * 0.11).delay(0.37.hz.lfo.sine.at(0.006..0.009) + sig.smooth(0.7692307692307692).at(-0.0007..0.0007)).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6).decimate(16000 - wear * 11000, mix: wear * 0.6).pan(-0.15)
sig2.and_then(silence(12)) + sig2.reverb(room_size: 0.7, decay: 6, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
