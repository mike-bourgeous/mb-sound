# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "ambient_rin",
  kind: :synth,
  saved: "2026-10-17T05:42:43Z",
  mb_sound: "0.12.0.usegit (504ed966)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :rin from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :rin, wear: 0.6, tune: -7.0, spread: 0.7 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"

sig = (synth(midi, voices: 4) { |v|
  v.trigger.resonate(:bowl, v.freq * 1.0, decay: 24, beat: 1.6, normalize: false)
} * 0.08).pan(0.15)
sig.and_then(silence(14)) + sig.reverb(room_size: 0.9, decay: 7, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
