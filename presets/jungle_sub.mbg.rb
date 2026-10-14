# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "jungle_sub",
  kind: :synth,
  saved: "2026-10-14T03:16:54Z",
  mb_sound: "0.12.0.usegit (796a1077)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :sub from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :sub, cutoff: 16000.0, echo: 0.3 }
inputs :midi

synth(midi, voices: 1) { |v|
  p = v.hz.glide(0.05, legato: true)
  (p.sine.free(true) + p.transpose(12).sine.free(true) * 0.15) * v.env(0.006, 0.2, 0.85, 0.12, gm: false).legato
} * 0.3
