# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "vinyl_specks",
  kind: :synth,
  saved: "2026-11-22T04:52:34Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "Vinyl specks: bandpassed crackle and a scratch every couple of seconds, bone dry.  It ignores notes.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :texture, :crackle, :noise],
  options: { patch: :vinyl_specks }
inputs midi: :notes
param :density, (1.0..200.0).at(14.0), description: "Specks per second"

sig = dust(density, bipolar: true)
sig2 = dust(100, min_gap: 1800.ms, range: 0.6..1)
sig.filter(:bandpass, cutoff: 1400, quality: 0.7) * 0.6 + sig2.filter(:highpass, cutoff: 300) * 0.5
