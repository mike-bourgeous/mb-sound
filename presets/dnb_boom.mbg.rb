# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "dnb_boom",
  kind: :synth,
  saved: "2026-10-17T04:18:21Z",
  mb_sound: "0.12.0.usegit (bdc41124)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :boom from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :boom, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs midi: :notes

synth(midi, voices: 1) { |n|
  dive = n.env(0, 0.25, 0, 0.1, curve: :linear, gm: false)
  ((n.freq * 2 ** (dive * 2)).tone * n.env(0.001, 1.2, 0, 0.3, gm: false) * 1.4).softclip(0.5, 0.95)
}.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.4
