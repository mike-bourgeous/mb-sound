# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "tiko_perc",
  kind: :synth,
  saved: "2026-10-13T10:01:34Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/tiko_marvell.rb",
  options: { patch: :perc, dub: 0.0, keep: 0.82 }
inputs :midi

tr808(midi, only: [:maracas, :rimshot, :low_conga, :mid_conga], velocity_curve: :midi, maracas: { decay: 0.05 }, rimshot: { tune: 1700 }, low_conga: { tune: 190 }, mid_conga: { tune: 280 }, seed: drawn_seed(900450186894289455)).filter(:highpass, cutoff: 180) * 1.2
