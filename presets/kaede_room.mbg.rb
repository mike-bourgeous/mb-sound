# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kaede_room",
  kind: :effect,
  saved: "2026-10-13T10:01:56Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/kaede_rowntree.rb"
inputs :input
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1"

input.and_then(silence(16)) + input.reverb(room_size: 0.9, decay: 8, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
