# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "funk_perc",
  kind: :synth,
  saved: "2026-10-28T06:22:20Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :perc from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :perc, dub: nil, keep: nil, bite: nil, body: nil, cutoff: nil, glide: nil, echo: nil, attack: nil, decay: nil, release: nil }
inputs midi: :notes

tr808(midi, only: [:maracas, :rimshot, :low_conga, :mid_conga], velocity_curve: :midi, maracas: { decay: 0.05 }, rimshot: { tune: 1700 }, low_conga: { tune: 190 }, mid_conga: { tune: 280 }, seed: drawn_seed(900450186894289455)).filter(:highpass, cutoff: 180) * 1.2
