# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "jungle_pad",
  kind: :synth,
  saved: "2026-10-30T04:09:35Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :pad from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :pad, grit: nil, glide: nil, decay: nil, echo: nil }
inputs midi: :notes
param :cutoff, (20.0..16000.0).at(2400.0), description: "Lowpass cutoff in Hz (breaks 16000, pad 2400)"
param :attack, (0.001..8.0).at(1.2), description: "Attack in seconds (pad 1.2, flute 0.04)"
param :release, (0.001..10.0).at(1.8), description: "Release in seconds (sub 0.12, reese 0.15, pad 1.8)"

synth(midi, voices: 4, seed: drawn_seed(900450186894289455)) { |v|
  saws = v.hz.unison(5, detune: 22.cents) { |c, _i|
    c.saw
  }
  saws.filter(:lowpass, cutoff: cutoff, quality: 0.6) * v.env(attack, 1.0, 0.8, release, gm: false)
}.filter(:highpass, cutoff: 180, quality: 0.7).chorus(:juno12).reverb(:hall, mix: 0.35) * 0.085
