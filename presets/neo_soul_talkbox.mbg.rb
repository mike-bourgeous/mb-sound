# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "neo_soul_talkbox",
  kind: :synth,
  saved: "2026-10-13T14:59:38Z",
  mb_sound: "0.12.0.usegit (82c87ef8)",
  from: "bin/synths/neo_soul.rb",
  description: "Funk / neo-soul patch :talkbox from bin/synths/neo_soul.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :talkbox, dub: 0.0, keep: 0.82 }
inputs :midi

synth(midi, voices: 1) { |v|
  f = v.hz.glide(0.045).vibrato(5.2, depth: 0.25, delay: 0.25)
  buzz = f.transpose(-12)
  sig = buzz.saw * 0.6 + buzz.pulse(0.2) * 0.5
  src = sig + sig.filter(:highpass, cutoff: 1800, quality: 0.7) * 0.7
  morph = v.filter_env(0.06, 0.35, 0.55, 0.2)
  mouth = src.formant(:u, :o, :a, :e, morph: morph, shift: (v.number - 62) * 0.25, width: 0.45)
  (mouth * 2).softclip(0.6, 0.95) * v.amp_env(0.01, 0.4, 0.75, 0.12) * 1.05
}.delay(1.n8.dotted, feedback: 0.25, wet: 0.22, dry: 1) * 0.75
