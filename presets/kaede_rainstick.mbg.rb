# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kaede_rainstick",
  kind: :synth,
  saved: "2026-10-13T09:31:15Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kaede_rowntree.rb",
  options: { patch: :rainstick, space: 0.5, wear: 0.0 }
inputs :midi

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |n|
  swell = n.env(2.8, 5, 0, 1.5, curve: :gentle, gm: false)
  osc = noise
  clicks = (osc.aabs - 0.9854166666666667).aclip(0, nil) * 68.57142857142857
  osc2 = noise
  pitch = osc2.sample_hold(clicks) * 1800 + 4200
  where = adsr(0, 9, 0, 0, trigger: n.trigger, curve: :linear) * 1.4 - 0.7
  (clicks.ping(pitch, decay: 0.012) * 0.25 * swell).pan(where)
} * 1.6
