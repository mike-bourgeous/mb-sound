# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "fm_ep",
  kind: :synth,
  saved: "2026-11-13T06:47:09Z",
  mb_sound: "0.12.0.usegit (366bde7)",
  from: "bin/synths/library_voices.rb",
  description: "FM electric piano: a sine phase-modulated by a sine at the note (the body, its bark falling fast after the strike, harder notes brighter) plus a tine pair, a sine modulated at 14 times the note for a short metallic ting; a quick drop after the strike into a long decay, shorter up the keyboard; chord notes humanized by a few milliseconds (FM / PM (two operator pairs); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:fm, :pm, :electric_piano, :keys],
  options: { patch: :fm_ep }
inputs midi: :notes
param :index, (0.0..10.0).at(2.5), description: "Body modulation index in radians at the strike (the bark; velocity scales it)"
param :ratio, (0.5..8.0).at(1.0), description: "Body modulator frequency over the note's (1: harmonic; 3.5: bell-like)"
param :tine, (0.0..4.0).at(1.4), description: "Tine pair's modulation index at the strike (the metallic ting)"
param :decay, (0.05..12.0).at(4.0), description: "Seconds the tail decays at C4 (an octave up: 0.7 times as long)"
param :release, (0.01..5.0).at(0.3), description: "Release in seconds"

synth(midi.humanize(0.01, seed: 900450186894289455), voices: 8) { |v|
  sig = v.velocity
  sig2 = v.hz
  sig3 = v.freq
  (sig2.sine.pm(((sig3 * ratio).tone.sine * (index * (0.3 + 0.7 * sig) * v.env(0.001, 0.25, 0.3, release, gm: false).no_velocity)).radians) * (v.env(0.001, 0.35, 0, release, gm: false) * 0.45 + v.env(0.001, decay * 2 ** ((60 - v.number) / 24.0), 0, release, gm: false) * 0.55) + sig2.sine.pm(((sig3 * 14).tone.sine * (tine * sig * v.env(0.0, 0.18, 0, 0.05, gm: false, curve: :dx).no_velocity)).radians) * 0.5 * v.env(0.001, 0.4, 0, 0.1, gm: false).no_velocity * sig) * 0.33
}.filter(:highpass, cutoff: 20, quality: 0.7071)
