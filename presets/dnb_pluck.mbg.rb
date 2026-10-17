# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "dnb_pluck",
  kind: :synth,
  saved: "2026-10-17T04:18:15Z",
  mb_sound: "0.12.0.usegit (bdc41124)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :pluck from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :pluck, cutoff: 2400.0, grit: 0.25 }
inputs midi: :notes
param :echo, 0.4, range: 0.0..1.0, description: "Pluck delay send (echo level) 0..1"

synth(midi, voices: 2) { |v|
  fenv = v.env(0.001, 0.18, 0.0, 0.1, gm: false)
  tone = v.hz.square.lp4(500 * 2 ** (fenv * 3), resonance: 0.3)
  tone * v.env(0.002, 0.35, 0.0, 0.15, gm: false) * 0.5
}.delay(1.n8.dotted, feedback: 0.4, wet: echo, dry: 1).reverb(:plate, mix: 0.25, output_channels: 2)
