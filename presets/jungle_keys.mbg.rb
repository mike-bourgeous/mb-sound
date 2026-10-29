# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "jungle_keys",
  kind: :synth,
  saved: "2026-10-28T06:21:49Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/jungle.rb",
  description: "90s jungle patch :keys from bin/synths/jungle.rb, first made by Nev Ashdown (Skylark Junction), a fictional 90s atmospheric jungle producer, for the song \"Memory Card\" (bin/songs/memory_card.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-jungle).",
  options: { patch: :keys, cutoff: nil, grit: nil, glide: nil, attack: nil, release: nil, echo: nil }
inputs midi: :notes
param :decay, (0.1..20.0).at(4.5), description: "Keys decay in seconds (4.5)"

((synth(midi, voices: 8, retrigger: :string) { |v|
  f = v.hz
  sig = v.velocity
  vel2 = sig * sig
  index = v.env(0, 1.2, 0.1, 0.4, gm: false).no_velocity * (vel2 * 0.3 + 0.03)
  body = f.sine.free(true).pm(f.sine.free(true) * index)
  bell = f.sine.free(true).pm(f.transpose(45.68825906469125).sine.free(true) * v.env(0, 0.12, 0, 0.05, gm: false).no_velocity * (sig * 0.25))
  bar = f.transpose(12).sine.free(true) * v.env(0.001, 1.4, 0, 0.3, gm: false).no_velocity * 0.12
  x = (body + bell * 0.3 + bar) * v.amp_env(0.001, decay, 0, 0.35, curve: [12, 40, 40])
  x * (x * (sig * 0.5 * 0.5) + 1)
}.filter(:highpass, cutoff: 30, quality: 0.7) * 0.18).softclip(0.8, 0.95) * 1.8).pan(4.6.hz.lfo.at(0.22)).reverb(:hall, mix: 0.22) * 0.853574116818683
