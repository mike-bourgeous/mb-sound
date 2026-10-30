# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "funk_dub_loop",
  kind: :effect,
  saved: "2026-10-30T04:12:47Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/funk.rb",
  description: "Effect :funk_dub_loop from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper)."
inputs input: :audio
param :dub, (0.0..1.0).at(1.0), description: "Footswitch: 1 records into the 4-bar loop"
param :keep, (0.0..0.99).at(0.82), description: "Loop feedback per pass"

input + (input * dub).delay(4.bars, feedback: keep, wet: 1, dry: 0)
