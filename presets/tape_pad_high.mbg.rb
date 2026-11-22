# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "tape_pad_high",
  kind: :synth,
  saved: "2026-11-22T04:52:34Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "The tape pad's high layer (play it an octave up): a triangle and a quiet sharp saw per note through a brighter lp4, a slower swell, tape wow, and a Juno chorus.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :pad, :tape],
  options: { patch: :tape_pad_high }
inputs midi: :notes
param :cutoff, (100.0..8000.0).at(2200.0), description: "lp4 cutoff in Hz"
param :attack, (0.001..8.0).at(1.2), description: "Attack in seconds"
param :release, (0.01..10.0).at(1.6), description: "Release in seconds"

voice = synth(midi, voices: 8) { |v|
  sig = v.hz
  (sig.triangle + sig.transpose(0.1).saw * 0.3).lp4(cutoff, resonance: 0.1) * v.amp_env(attack, 0.5, 0.8, release)
}
sig = drift(0.8, smooth: :cosine)
voice.delay(sig.at(0.004..0.008) + 6.hz.lfo.at(0.0001)).chorus
