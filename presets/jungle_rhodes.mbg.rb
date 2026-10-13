# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "jungle_rhodes",
  kind: :synth,
  saved: "2026-10-13T14:42:55Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :rhodes from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :rhodes, cutoff: 16000.0, echo: 0.3 }
inputs :midi

voice = synth(midi, voices: 8) { |v|
  p = v.hz
  index = v.env(0.001, 0.5, 0.15, 0.3, gm: false)
  tine = p.transpose(33.68825906469125).sine * v.env(0.0005, 0.08, 0, 0.05, gm: false) * 0.06
  (p.sine.pm(p.sine, index * 0.22) + tine) * v.env(0.002, 1.6, 0.35, 0.35, gm: false)
}
lfo = 4.6.hz.lfo
stereo(voice * (lfo * 0.22 + 0.78), voice * (lfo * -0.22 + 0.78)).reverb(:hall, mix: 0.22) * 0.15
