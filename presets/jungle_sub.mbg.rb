# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "jungle_sub",
  kind: :synth,
  saved: "2026-10-30T04:08:59Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :sub from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :sub, cutoff: nil, grit: nil, glide: nil, attack: nil, decay: nil, echo: nil }
inputs midi: :notes
param :release, (0.001..10.0).at(0.12), description: "Release in seconds (sub 0.12, reese 0.15, pad 1.8)"

synth(midi, voices: 1) { |v|
  p = v.hz.glide(0.05, legato: true)
  (p.sine.free(true) + p.transpose(12).sine.free(true) * 0.15) * v.env(0.006, 0.2, 0.85, release, gm: false).legato
} * 0.3
