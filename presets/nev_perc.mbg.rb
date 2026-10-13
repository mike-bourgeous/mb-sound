# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "nev_perc",
  kind: :synth,
  saved: "2026-10-13T10:00:53Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/skylark_junction.rb",
  options: { patch: :perc, cutoff: 16000.0, echo: 0.3 }
inputs :midi

tr808(midi, cymbal: { decay: 0.9, tone: 0.7, level: 0.4 }, maracas: { decay: 0.05, level: 0.3 }, rimshot: { level: 0.2 }, accent: 6, seed: drawn_seed(900450186894289455)).filter(:highpass, cutoff: 300, quality: 0.7)
