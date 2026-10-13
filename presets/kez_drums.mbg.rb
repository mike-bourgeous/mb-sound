# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_drums",
  kind: :synth,
  saved: "2026-10-13T09:30:07Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :drums, cutoff: 2400.0, grit: 0.25, echo: 0.4 }
inputs :midi

tr808(midi, kick: { tune: 54, decay: 0.38, tone: 0.62, sigh: 0.9 }, snare: { tune: 205, decay: 0.2, snappy: 0.8, tone: 0.8, level: 0.95 }, clap: { decay: 0.16, tone: 0.8, level: 0.5 }, rimshot: { level: 0.35 }, closed_hat: { decay: 0.035, tone: 0.85, level: 0.55 }, open_hat: { decay: 0.16, tone: 0.7, level: 0.25 }, cymbal: { decay: 1.4, tone: 0.7, level: 0.3 }, maracas: { level: 0.25 }, low_tom: { tune: 120, decay: 0.35 }, accent: 6, seed: drawn_seed(900450186894289455)).compress(threshold: -24.db, ratio: 4, attack: 0.002, release: 0.06, makeup: 9, mix: 0.35)
