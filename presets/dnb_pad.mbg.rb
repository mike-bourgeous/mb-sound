# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "dnb_pad",
  kind: :synth,
  saved: "2026-10-28T06:21:29Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :pad from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :pad, resonance: nil, drive: nil, glide: nil, decay: nil, grit: nil, echo: nil, drop: nil }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(2600.0), description: "Lowpass cutoff in Hz (reese 2400 around its LFO, sub 110, neuro 600 and pluck 500 under their envelopes, pad 2600)"
param :attack, (0.001..8.0).at(0.6), description: "Pad attack in seconds (0.6)"
param :release, (0.001..10.0).at(1.2), description: "Release in seconds (sub 0.05, pad 1.2)"

synth(midi, voices: 10, seed: drawn_seed(900450186894289455)) { |v|
  saws = v.hz.unison(3, detune: 0.12) { |p, _i|
    p.saw
  }
  saws.lp4(cutoff, resonance: 0.1) * v.env(attack, 0.5, 0.8, release, gm: false) * 0.25
}.filter(:highpass, cutoff: 200, quality: 0.7).reverb(:hall, mix: 0.35, output_channels: 2)
