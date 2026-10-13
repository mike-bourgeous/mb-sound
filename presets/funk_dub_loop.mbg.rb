# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "funk_dub_loop",
  kind: :effect,
  saved: "2026-10-13T15:40:34Z",
  mb_sound: "0.12.0.usegit (31ee3867)",
  from: "bin/synths/funk.rb",
  description: "Effect :funk_dub_loop from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper)."
inputs :input
param :dub, 1.0, range: 0.0..1.0, description: "Footswitch: 1 records into the 4-bar loop"
param :keep, 0.82, range: 0.0..0.99, description: "Loop feedback per pass"

input + (input * dub).delay(4.bars, feedback: keep, wet: 1, dry: 0)
