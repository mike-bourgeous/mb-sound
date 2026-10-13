# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "tiko_bass",
  kind: :synth,
  saved: "2026-10-13T09:31:27Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/tiko_marvell.rb",
  options: { patch: :bass, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 2) { |v|
  f = v.hz
  env = v.amp_env(0.003, 0.5, 0.55, 0.05)
  cut = v.filter_env(0.002, 0.18, 0.15, 0.05) * v.velocity * 1400 + 160
  (f.sine * 0.8 + f.saw.lp4(cut, resonance: 0.25) * 0.55) * env
}.softclip(0.6, 0.95) * 0.55
