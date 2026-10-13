# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "jungle_flute",
  kind: :synth,
  saved: "2026-10-13T14:43:03Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :flute from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :flute, cutoff: 16000.0 }
inputs :midi
param :echo, 0.3, range: 0.0..1.0, description: "Flute echo send 0..1"

(synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  p = v.hz.glide(0.04, legato: true).vibrato(5.2, depth: 15.cents, delay: 0.25)
  air = noise.filter(:bandpass, cutoff: 2600, quality: 1.2) * 0.05
  (p.triangle * 0.6 + p.sine * 0.5 + air) * v.env(0.04, 0.3, 0.8, 0.25, gm: false)
} * 0.17).delay(1.n8.dotted, feedback: 0.35, wet: echo, dry: 1).reverb(:hall, mix: 0.25)
