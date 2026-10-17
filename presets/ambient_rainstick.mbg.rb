# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "ambient_rainstick",
  kind: :synth,
  saved: "2026-10-17T04:19:50Z",
  mb_sound: "0.12.0.usegit (bdc41124)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :rainstick from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :rainstick, space: 0.5, wear: 0.6, tune: -7.0, spread: 0.7 }
inputs midi: :notes

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |n|
  swell = n.env(2.8, 5, 0, 1.5, curve: :gentle, gm: false)
  clicks = dust(700)
  osc = noise
  pitch = osc.sample_hold(clicks) * 1800 + 4200
  where = adsr(0, 9, 0, 0, trigger: n.trigger, curve: :linear) * 1.4 - 0.7
  (clicks.ping(pitch, decay: 0.012) * 0.25 * swell).pan(where)
} * 1.6
