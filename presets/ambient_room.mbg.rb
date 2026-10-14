# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "ambient_room",
  kind: :effect,
  saved: "2026-10-14T03:18:39Z",
  mb_sound: "0.12.0.usegit (796a1077)",
  from: "bin/synths/ambient.rb",
  description: "Effect :ambient_room from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen)."
inputs :input
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1"

input.and_then(silence(16)) + input.reverb(room_size: 0.9, decay: 8, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
