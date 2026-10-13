# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "funk_talkbox",
  kind: :synth,
  saved: "2026-10-13T16:48:40Z",
  mb_sound: "0.12.0.usegit (5f5c51c6)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :talkbox from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :talkbox, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 1) { |v|
  f = v.hz.glide(0.045).vibrato(5.2, depth: 0.25, delay: 0.25)
  buzz = f.transpose(-12)
  sig = buzz.saw * 0.6 + buzz.pulse(0.2) * 0.5
  src = sig + sig.filter(:highpass, cutoff: 1800, quality: 0.7) * 0.7
  morph = v.filter_env(0.06, 0.35, 0.55, 0.2) * 0.7 + v.lfo(1.n8, shape: :triangle, unipolar: true, phase: 0.75) * 0.6
  shift = (v.number - 62) * 0.25 + v.lfo(1.bar, shape: :sine) * 0.6
  mouth = src.formant(:u, :o, :a, :e, morph: morph, shift: shift, width: 0.45)
  (mouth * 2).softclip(0.6, 0.95) * v.amp_env(0.01, 0.4, 0.75, 0.12) * 1.05
}.delay(1.n8.dotted, feedback: 0.25, wet: 0.22, dry: 1) * 0.75
