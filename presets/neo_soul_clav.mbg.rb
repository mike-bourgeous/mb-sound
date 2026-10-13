# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "neo_soul_clav",
  kind: :synth,
  saved: "2026-10-13T14:43:54Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/neo_soul.rb",
  description: "Funk / neo-soul patch :clav from bin/synths/neo_soul.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :clav, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 4) { |v|
  v.hz.pulse(0.2).filter(:highpass, cutoff: 400).lp4(3500) * v.amp_env(0.001, 0.12, 0, 0.04) * 0.6
}
