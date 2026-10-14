# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "funk_bass",
  kind: :synth,
  saved: "2026-10-14T02:45:37Z",
  mb_sound: "0.12.0.usegit (94c421d7)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :bass from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :bass, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 2) { |v|
  f = v.hz
  env = v.amp_env(0.003, 0.5, 0.55, 0.05)
  cut = v.filter_env(0.002, 0.18, 0.15, 0.05) * v.velocity * 1400 + 160
  (f.sine * 0.8 + f.saw.lp4(cut, resonance: 0.25) * 0.55) * env
}.softclip(0.6, 0.95) * 0.55
