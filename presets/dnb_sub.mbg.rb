# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "dnb_sub",
  kind: :synth,
  saved: "2026-10-30T06:32:54Z",
  mb_sound: "0.12.0.usegit (28b121e2)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :sub from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :sub, resonance: nil, drive: nil, glide: nil, attack: nil, decay: nil, grit: nil, echo: nil, drop: nil }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(110.0), description: "Lowpass cutoff in Hz (reese 2400 around its LFO, sub 110, neuro 600 and pluck 500 under their envelopes, pad 2600)"
param :release, (0.001..10.0).at(0.05), description: "Release in seconds (sub 0.05, pad 1.2)"

synth(midi, voices: 1) { |v|
  pitch = v.hz.glide(0.035, legato: true)
  env = v.env(0.003, 0.3, 0.9, release, gm: false).legato
  upper = pitch.transpose(12).sine * 0.2 + pitch.transpose(19.019550008653873).sine * 0.1
  ((pitch.sine * env).filter(:lowpass, cutoff: cutoff, quality: 0.7) + upper * env) * 0.9759000729485331
}
