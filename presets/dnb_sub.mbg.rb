# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "dnb_sub",
  kind: :synth,
  saved: "2026-10-17T04:17:56Z",
  mb_sound: "0.12.0.usegit (bdc41124)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :sub from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :sub, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs midi: :notes

synth(midi, voices: 1) { |v|
  pitch = v.hz.glide(0.035, legato: true)
  env = v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato
  upper = pitch.transpose(12).sine * 0.2 + pitch.transpose(19.019550008653873).sine * 0.1
  ((pitch.sine * env).filter(:lowpass, cutoff: 110, quality: 0.7) + upper * env) * 0.9759000729485331
}
