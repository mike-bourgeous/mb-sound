# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "tiko_dub_loop",
  kind: :effect,
  saved: "2026-10-13T10:01:56Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/tiko_marvell.rb"
inputs :input
param :dub, 1.0, range: 0.0..1.0, description: "Footswitch: 1 records into the 4-bar loop"
param :keep, 0.82, range: 0.0..0.99, description: "Loop feedback per pass"

input + (input * dub).delay(4.bars, feedback: keep, wet: 1, dry: 0)
