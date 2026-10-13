# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_boom",
  kind: :synth,
  saved: "2026-10-13T09:30:04Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :boom, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs :midi

synth(midi, voices: 1) { |n|
  dive = n.env(0, 0.25, 0, 0.1, curve: :linear, gm: false)
  ((n.freq * 2 ** (dive * 2)).tone * n.env(0.001, 1.2, 0, 0.3, gm: false) * 1.4).softclip(0.5, 0.95)
}.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.4
