# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "funk_clav",
  kind: :synth,
  saved: "2026-10-13T15:40:14Z",
  mb_sound: "0.12.0.usegit (31ee3867)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :clav from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :clav, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 4) { |v|
  v.hz.pulse(0.2).filter(:highpass, cutoff: 400).lp4(3500) * v.amp_env(0.001, 0.12, 0, 0.04) * 0.6
}
