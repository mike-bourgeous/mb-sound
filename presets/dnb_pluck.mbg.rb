# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "dnb_pluck",
  kind: :synth,
  saved: "2026-10-30T06:33:05Z",
  mb_sound: "0.12.0.usegit (28b121e2)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :pluck from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :pluck, resonance: nil, drive: nil, glide: nil, attack: nil, release: nil, grit: nil, drop: nil }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(500.0), description: "Lowpass cutoff in Hz (reese 2400 around its LFO, sub 110, neuro 600 and pluck 500 under their envelopes, pad 2600)"
param :decay, (0.01..8.0).at(0.35), description: "Amplitude decay in seconds (neuro 0.12: its filter envelope too; pluck 0.35, boom 1.2)"
param :echo, (0.0..1.0).at(0.4), description: "Pluck delay send (echo level) 0..1 (0.4)"

synth(midi, voices: 2) { |v|
  fenv = v.env(0.001, 0.18, 0.0, 0.1, gm: false)
  tone = v.hz.square.lp4(cutoff * 2 ** (fenv * 3), resonance: 0.3)
  tone * v.env(0.002, decay, 0.0, 0.15, gm: false) * 0.5
}.delay(1.n8.dotted, feedback: 0.4, wet: echo, dry: 1).reverb(:plate, mix: 0.25, output_channels: 2)
