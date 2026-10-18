# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "jungle_pad",
  kind: :synth,
  saved: "2026-10-18T07:25:43Z",
  mb_sound: "0.12.0.usegit (7ffa245e)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :pad from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :pad, cutoff: 16000.0, echo: 0.3 }
inputs midi: :notes

synth(midi, voices: 4, seed: drawn_seed(900450186894289455)) { |v|
  saws = v.hz.unison(5, detune: 22.cents) { |c, _i|
    c.ramp
  }
  saws.filter(:lowpass, cutoff: 2400, quality: 0.6) * v.env(1.2, 1.0, 0.8, 1.8, gm: false)
}.filter(:highpass, cutoff: 180, quality: 0.7).chorus(:juno12).reverb(:hall, mix: 0.35) * 0.085
