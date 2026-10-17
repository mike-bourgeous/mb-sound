# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "ambient_bowl",
  kind: :synth,
  saved: "2026-10-17T17:17:13Z",
  mb_sound: "0.12.0.usegit (47598381)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :bowl from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :bowl, wear: 0.6, tune: -7.0, spread: 0.7 }
inputs midi: :notes
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"

sig = (synth(midi, voices: 6) { |v|
  v.trigger.resonate(:bowl, v.freq * 1.0, decay: 24, beat: 0.7, normalize: false)
} * 0.12).pan(0)
sig.and_then(silence(18)) + sig.reverb(room_size: 0.9, decay: 9, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
