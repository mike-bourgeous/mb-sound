# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "jungle_reese",
  kind: :synth,
  saved: "2026-10-28T06:21:46Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :reese from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :reese, cutoff: nil, grit: nil, attack: nil, decay: nil, echo: nil }
inputs midi: :notes
param :glide, (0.0..0.5).at(0.06), description: "Legato glide in seconds (reese 0.06, flute 0.04)"
param :release, (0.001..10.0).at(0.15), description: "Release in seconds (sub 0.12, reese 0.15, pad 1.8)"

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  p = v.hz.glide(glide, legato: true)
  saws = p.unison(2, detune: 16.cents, phase: 0.0) { |c, _i|
    c.saw.free(true)
  }
  breath = 1.bar.hz.transpose(-12).lfo.at(260..700)
  body = saws.lp4(breath, resonance: 0.2)
  (body * 0.9 + p.sine.free(true) * 0.6) * v.env(0.02, 0.3, 0.9, release, gm: false).legato
}.softclip(0.5, 0.95) * 0.32
