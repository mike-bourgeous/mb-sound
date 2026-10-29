# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "funk_bass",
  kind: :synth,
  saved: "2026-10-28T06:22:23Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :bass from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :bass, dub: nil, keep: nil, body: nil, cutoff: nil, glide: nil, echo: nil, attack: nil, release: nil }
inputs midi: :notes
param :bite, (0.0..8000.0).at(1400.0), description: "Bass filter envelope depth in Hz above 160, times velocity (1400)"
param :decay, (0.01..10.0).at(0.5), description: "Decay in seconds (bass 0.5, keys 3, clav 0.12)"

synth(midi, voices: 2) { |v|
  f = v.hz
  env = v.amp_env(0.003, decay, 0.55, 0.05)
  cut = v.filter_env(0.002, 0.18, 0.15, 0.05) * v.velocity * bite + 160
  (f.sine * 0.8 + f.saw.lp4(cut, resonance: 0.25) * 0.55) * env
}.softclip(0.6, 0.95) * 0.55
