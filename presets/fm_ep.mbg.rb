# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "fm_ep",
  kind: :synth,
  saved: "2026-11-13T02:28:29Z",
  mb_sound: "0.12.0.usegit (fa5909f)",
  from: "bin/synths/library_voices.rb",
  description: "Two-operator FM electric piano: a sine phase-modulated by a sine whose index falls after the strike (harder notes brighter), plus a short high tine for the bark (FM / PM (two operators); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:fm, :pm, :electric_piano, :keys],
  options: { patch: :fm_ep }
inputs midi: :notes
param :index, (0.0..10.0).at(2.2), description: "Modulation index in radians at the strike (brightness)"
param :ratio, (0.5..8.0).at(1.0), description: "Modulator frequency over the note's (1: harmonic; 3.5: bell-like)"
param :tine, (0.0..2.0).at(0.6), description: "Level of the short high tine (14x) at the strike"
param :decay, (0.05..10.0).at(2.0), description: "Amplitude decay in seconds"
param :release, (0.01..5.0).at(0.35), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  sig = v.freq
  v.hz.sine.pm(((sig * ratio).tone.sine * (index * v.env(0.001, 0.9, 0.2, release, gm: false)) + (sig * 14).tone.sine * tine * v.env(0.0, 0.06, 0, 0.05, gm: false)).radians) * v.env(0.002, decay, 0.0, release, gm: false) * 0.41
}.filter(:highpass, cutoff: 20, quality: 0.7071)
