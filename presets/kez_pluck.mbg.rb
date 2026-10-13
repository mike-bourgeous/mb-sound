# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_pluck",
  kind: :synth,
  saved: "2026-10-13T10:00:12Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :pluck, cutoff: 2400.0, grit: 0.25 }
inputs :midi
param :echo, 0.4, range: 0.0..1.0, description: "Pluck delay send (echo level) 0..1"

synth(midi, voices: 2) { |v|
  fenv = v.env(0.001, 0.18, 0.0, 0.1, gm: false)
  tone = v.hz.square.lp4(500 * 2 ** (fenv * 3), resonance: 0.3)
  tone * v.env(0.002, 0.35, 0.0, 0.15, gm: false) * 0.5
}.delay(1.n8.dotted, feedback: 0.4, wet: echo, dry: 1).reverb(:plate, mix: 0.25, output_channels: 2)
