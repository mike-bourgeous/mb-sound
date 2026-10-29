# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "funk_choir",
  kind: :synth,
  saved: "2026-10-28T06:22:34Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :choir from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :choir, bite: nil, body: nil, cutoff: nil, glide: nil, echo: nil, decay: nil }
inputs midi: :notes
param :dub, (0.0..1.0).at(0.0), description: "Choir looper footswitch: 1 records into the loop (0)"
param :keep, (0.0..0.99).at(0.82), description: "Choir looper feedback per pass 0..1 (0.82)"
param :attack, (0.001..8.0).at(0.35), description: "Choir attack in seconds (0.35)"
param :release, (0.001..10.0).at(0.8), description: "Choir release in seconds (0.8)"

fx = synth(midi, voices: 4) { |v|
  f = v.hz.vibrato(4.6, depth: 0.12)
  (f.saw * 0.5 + f.transpose(0.07).saw * 0.5).formant(:u, :o, morph: 0.6, voice: :alto) * v.amp_env(attack, 1.0, 0.8, release) * 0.36
}.filter(:highpass, cutoff: 220)
fx + (fx * dub).delay(4.bars, feedback: keep, wet: 1, dry: 0)
