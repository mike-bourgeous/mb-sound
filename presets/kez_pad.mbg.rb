# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_pad",
  kind: :synth,
  saved: "2026-10-13T09:29:55Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :pad, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs :midi

synth(midi, voices: 10, seed: drawn_seed(900450186894289455)) { |v|
  saws = v.hz.unison(3, detune: 0.12) { |p, _i|
    p.saw
  }
  saws.lp4(2600, resonance: 0.1) * v.env(0.6, 0.5, 0.8, 1.2, gm: false) * 0.25
}.filter(:highpass, cutoff: 200, quality: 0.7).reverb(:hall, mix: 0.35, output_channels: 2)
