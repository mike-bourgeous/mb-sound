# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "funk_choir",
  kind: :synth,
  saved: "2026-10-17T17:18:28Z",
  mb_sound: "0.12.0.usegit (47598381)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :choir from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :choir }
inputs midi: :notes
param :dub, 0.0, range: 0.0..1.0, description: "Choir looper footswitch: 1 records into the loop"
param :keep, 0.82, range: 0.0..0.99, description: "Choir looper feedback per pass 0..1"

fx = synth(midi, voices: 4) { |v|
  f = v.hz.vibrato(4.6, depth: 0.12)
  (f.saw * 0.5 + f.transpose(0.07).saw * 0.5).formant(:u, :o, morph: 0.6, voice: :alto) * v.amp_env(0.35, 1.0, 0.8, 0.8) * 0.36
}.filter(:highpass, cutoff: 220)
fx + (fx * dub).delay(4.bars, feedback: keep, wet: 1, dry: 0)
