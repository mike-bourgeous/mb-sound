# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "talking_sub",
  kind: :synth,
  saved: "2026-11-22T04:52:33Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "A talking sub: a sine with whole-number FM on top so it locks to the note, 3x as each note speaks and 4x breathing over four bars, lowpassed (attack 1.2 for a swell).  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :fm, :sub, :bass, :mono],
  options: { patch: :talking_sub }
inputs midi: :notes
param :attack, (0.001..4.0).at(0.03), description: "Amplitude attack in seconds (1.2: a swell)"
param :cutoff, (100.0..2000.0).at(420.0), description: "Lowpass cutoff in Hz"

lfo = 4.bars.hz.lfo.at(0.1..1.0)
synth(midi, voices: 1) { |v|
  f = v.hz.glide(60.ms)
  grunt = v.env(0.004, 0.22, 0.3, 0.05)
  f.fm(f.transpose(19.019550008653873).at(90) * grunt + f.transpose(24).at(150) * lfo * grunt) * v.amp_env(attack, 0.1, 1.0, 0.1)
}.filter(:lowpass, cutoff: cutoff)
