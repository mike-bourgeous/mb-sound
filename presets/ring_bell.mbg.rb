# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "ring_bell",
  kind: :synth,
  saved: "2026-11-13T02:06:32Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Ring-modulated bell: a sine times a sine at an inharmonic ratio (sum and difference tones), the ring fading toward a plain sine as the note decays (AM / ring modulation; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:am, :ring_mod, :metallic, :keys],
  options: { patch: :ring_bell }
inputs midi: :notes
param :ratio, (0.25..8.0).at(3.53), description: "Modulator frequency over the note's (3.53: bell-like; whole numbers: harmonic)"
param :ring, (0.0..1.0).at(1.0), description: "Modulation: 0 a plain sine, 0.5 AM, 1 ring modulation (at the strike; it fades with ring_decay)"
param :ring_decay, (0.01..10.0).at(0.8), description: "Seconds the ring takes to fade toward the plain sine"
param :decay, (0.05..10.0).at(2.5), description: "Amplitude decay in seconds"
param :release, (0.01..5.0).at(0.6), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  sig = ring * v.env(0.0, ring_decay, 0.25, release, gm: false).no_velocity
  v.hz.sine * (1 - sig + (v.freq * ratio).tone.sine * sig) * v.env(0.002, decay, 0.0, release, gm: false) * 0.45
}
