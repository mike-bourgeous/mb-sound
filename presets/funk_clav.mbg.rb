# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "funk_clav",
  kind: :synth,
  saved: "2026-10-30T04:11:04Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :clav from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :clav, dub: nil, keep: nil, bite: nil, body: nil, glide: nil, echo: nil, attack: nil, release: nil }
inputs midi: :notes
param :cutoff, (200.0..16000.0).at(3500.0), description: "Clav lowpass cutoff in Hz (3500)"
param :decay, (0.01..10.0).at(0.12), description: "Decay in seconds (bass 0.5, keys 3, clav 0.12)"

synth(midi, voices: 4) { |v|
  v.hz.pulse(0.2).filter(:highpass, cutoff: 400).lp4(cutoff) * v.amp_env(0.001, decay, 0, 0.04) * 0.6
}
