# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "jungle_flute",
  kind: :synth,
  saved: "2026-10-30T04:09:41Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :flute from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :flute, cutoff: nil, grit: nil, decay: nil, release: nil }
inputs midi: :notes
param :glide, (0.0..0.5).at(0.04), description: "Legato glide in seconds (reese 0.06, flute 0.04)"
param :attack, (0.001..8.0).at(0.04), description: "Attack in seconds (pad 1.2, flute 0.04)"
param :echo, (0.0..1.0).at(0.3), description: "Flute echo send 0..1 (0.3)"

(synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  p = v.hz.glide(glide, legato: true).vibrato(5.2, depth: 15.cents, delay: 0.25)
  air = noise.filter(:bandpass, cutoff: 2600, quality: 1.2) * 0.05
  (p.triangle.free(true) * 0.6 + p.sine.free(true) * 0.5 + air) * v.env(attack, 0.3, 0.8, 0.25, gm: false)
} * 0.17).delay(1.n8.dotted, feedback: 0.35, wet: echo, dry: 1).reverb(:hall, mix: 0.25)
