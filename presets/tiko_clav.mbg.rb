# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "tiko_clav",
  kind: :synth,
  saved: "2026-10-13T09:31:35Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/tiko_marvell.rb",
  options: { patch: :clav, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 4) { |v|
  v.hz.pulse(0.2).filter(:highpass, cutoff: 400).lp4(3500) * v.amp_env(0.001, 0.12, 0, 0.04) * 0.6
}
