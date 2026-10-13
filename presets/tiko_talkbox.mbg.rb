# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "tiko_talkbox",
  kind: :synth,
  saved: "2026-10-13T10:01:51Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/tiko_marvell.rb",
  options: { patch: :talkbox, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 1) { |v|
  f = v.hz.glide(0.045).vibrato(5.2, depth: 0.25, delay: 0.25)
  src = f.saw * 0.6 + f.pulse(0.3) * 0.4
  morph = v.filter_env(0.06, 0.35, 0.55, 0.2)
  src.formant(:o, :a, :e, morph: morph, shift: (v.number - 62) * 0.25, width: 1.0) * v.amp_env(0.01, 0.4, 0.75, 0.12) * 0.45
}.delay(1.n8.dotted, feedback: 0.25, wet: 0.22, dry: 1) * 0.75
