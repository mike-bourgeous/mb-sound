# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "ambient_harp",
  kind: :synth,
  saved: "2026-10-13T14:43:27Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :harp from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :harp }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"
param :wear, 0.0, range: 0.0..1.0, description: "Tape wear 0..1 (koto, harp)"

voice = synth(midi, voices: 3, seed: drawn_seed(900450186894289455)) { |v|
  fx = v.velocity.aease(:quad_out, out: 0.0..1.0)
  sig = v.freq
  sig2 = v.period
  fx2 = sig.aease(:smoothstep, in: 707.1067811865474..1414.213562373095)
  sig3 = 1 - fx
  sig4 = fx2 + (1 - fx2) * sig3
  osc = noise
  osc2 = noise
  sig5 = osc2.filter(:lowpass, cutoff: 1500 * 7.0.constant ** fx, quality: 0.6) * v.env(0, 0.008, 0, 0.008, gm: false, sensitivity: 0.3..1.0) * (((1200.0 / sig) ** 0.531508495181978).aclip(1, 100) * 2.8.db) * ((1 - fx2) * fx ** 0.5)
  sig6 = 10.constant ** (-1.2 / sig)
  sig7 = sig * (6.0 - 4.0 * v.cc(1, range: 0.0..1.0, name: "Damping", description: "Darkens the string (loop lowpass)"))
  (osc.filter(:lowpass, cutoff: sig * 6.0.constant ** fx, quality: 0.6) * v.env(0, 0, 1, 0, gate: false, gm: false, hold: sig2 * 1.0, sensitivity: 0.3..1.0) * (fx2 + (1 - fx2) * sig3 ** 0.5)).feedback { |fb, input|
    line = fb + input
    d = line.delay(sig2, smooth: false, max_delay: 0.08)
    s = ((d + d.delay(1.samples)) * (sig6 * 0.5)).filter(:lowpass, cutoff: sig7, quality: 0.7071067811865476)
    s + sig5
  } * v.amp_env([[0, sig2 * sig4, 0, :exp], [1, sig2 * (sig4 + 1), 0, :exp], [0, 0.08]]) * 4
}
sig = 1.3.hz.lfo.square.sample_hold(seed: drawn_seed(3969543146641149120))
sig2 = (voice * 0.14).delay(0.37.hz.lfo.sine.at(0.006..0.009) + sig.smooth(0.7692307692307692).at(-0.0007..0.0007)).filter(:lowpass, cutoff: 9000 - wear * 7800, quality: 0.6).decimate(16000 - wear * 11000, mix: wear * 0.6).pan(0.3)
sig2.and_then(silence(10)) + sig2.reverb(room_size: 0.6, decay: 5, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
