# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "dnb_boom",
  kind: :synth,
  saved: "2026-10-28T06:21:34Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :boom from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :boom, cutoff: nil, resonance: nil, drive: nil, glide: nil, attack: nil, release: nil, grit: nil, echo: nil }
inputs midi: :notes
param :decay, (0.01..8.0).at(1.2), description: "Amplitude decay in seconds (neuro 0.12: its filter envelope too; pluck 0.35, boom 1.2)"
param :drop, (0.0..4.0).at(2.0), description: "Boom pitch dive in octaves onto the note (2)"

synth(midi, voices: 1) { |n|
  dive = n.env(0, 0.25, 0, 0.1, curve: :linear, gm: false)
  ((n.freq * 2 ** (dive * drop)).tone * n.env(0.001, decay, 0, 0.3, gm: false) * 1.4).softclip(0.5, 0.95)
}.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.4
