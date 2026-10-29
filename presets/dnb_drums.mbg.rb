# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "dnb_drums",
  kind: :synth,
  saved: "2026-10-28T06:21:37Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :drums from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :drums, cutoff: nil, resonance: nil, drive: nil, glide: nil, attack: nil, decay: nil, release: nil, grit: nil, echo: nil, drop: nil }
inputs midi: :notes

tr808(midi, kick: { tune: 54, decay: 0.38, tone: 0.62, sigh: 0.9 }, snare: { tune: 205, decay: 0.2, snappy: 0.8, tone: 0.8, level: 0.95 }, clap: { decay: 0.16, tone: 0.8, level: 0.5 }, rimshot: { level: 0.35 }, closed_hat: { decay: 0.035, tone: 0.85, level: 0.55 }, open_hat: { decay: 0.16, tone: 0.7, level: 0.25 }, cymbal: { decay: 1.4, tone: 0.7, level: 0.3 }, maracas: { level: 0.25 }, low_tom: { tune: 120, decay: 0.35 }, accent: 6.db, seed: drawn_seed(900450186894289455)).compress(threshold: -24.db, ratio: 4, attack: 0.002, release: 0.06, makeup: 9.db, mix: 0.35)
