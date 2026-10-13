# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "dnb_sub",
  kind: :synth,
  saved: "2026-10-13T14:42:18Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :sub from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :sub, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs :midi

synth(midi, voices: 1) { |v|
  pitch = v.hz.glide(0.035, legato: true)
  (pitch.sine * v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato).filter(:lowpass, cutoff: 110, quality: 0.7)
}
