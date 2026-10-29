# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "ambient_bowl",
  kind: :synth,
  saved: "2026-10-28T06:21:59Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :bowl from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :bowl, attack: nil, release: nil, tip: nil, wear: 0.6, tune: -7.0, spread: 0.7 }
inputs midi: :notes
param :space, (0.0..1.0).at(0.5), description: "Room level 0..1 (bowls, rin, gong, koto, harp)"
param :decay, (0.1..60.0).at(24.0), description: "Decay in seconds (bowl and rin 24, koto 3.2)"

sig = (synth(midi, voices: 6) { |v|
  v.trigger.resonate(:bowl, v.freq * 1.0, decay: decay, beat: 0.7, normalize: false)
} * 0.12).pan(0)
sig.and_then(silence(18)) + sig.reverb(room_size: 0.9, decay: 9, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
