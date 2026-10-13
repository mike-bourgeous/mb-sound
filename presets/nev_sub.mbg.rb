# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "nev_sub",
  kind: :synth,
  saved: "2026-10-13T09:30:17Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/skylark_junction.rb",
  options: { patch: :sub, cutoff: 16000.0, echo: 0.3 }
inputs :midi

synth(midi, voices: 1) { |v|
  p = v.hz.glide(0.05, legato: true)
  (p.sine + p.transpose(12).sine * 0.15) * v.env(0.006, 0.2, 0.85, 0.12, gm: false).legato
} * 0.3
