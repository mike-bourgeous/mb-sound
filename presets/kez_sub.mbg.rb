# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_sub",
  kind: :synth,
  saved: "2026-10-13T09:59:59Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :sub, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs :midi

synth(midi, voices: 1) { |v|
  pitch = v.hz.glide(0.035, legato: true)
  (pitch.sine * v.env(0.003, 0.3, 0.9, 0.05, gm: false).legato).filter(:lowpass, cutoff: 110, quality: 0.7)
}
