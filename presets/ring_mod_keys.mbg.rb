# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "ring_mod_keys",
  kind: :synth,
  saved: "2026-11-13T06:46:32Z",
  mb_sound: "0.12.0.usegit (366bde7)",
  from: "bin/synths/library_voices.rb",
  description: "Ring-modulated keys: a sine times a sine at an inharmonic ratio (sum and difference tones, a metallic clang), the modulation fading toward the plain sine as the note decays (AM / ring modulation; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:am, :ring_mod, :metallic, :keys],
  options: { patch: :ring_mod_keys }
inputs midi: :notes
param :ratio, (0.25..8.0).at(3.53), description: "Modulator frequency over the note's (3.53: clangy; whole numbers: harmonic)"
param :depth, (0.0..1.0).at(1.0), description: "Modulation at the strike: 0 a plain sine, 0.5 AM, 1 ring modulation (it fades with depth_decay)"
param :depth_decay, (0.01..10.0).at(0.8), description: "Seconds the modulation takes to fade toward a quarter of its depth"
param :decay, (0.05..10.0).at(2.5), description: "Amplitude decay in seconds"
param :release, (0.01..5.0).at(0.6), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  sig = depth * v.env(0.0, depth_decay, 0.25, release, gm: false).no_velocity
  v.hz.sine * (1 - sig + (v.freq * ratio).tone.sine * sig) * v.env(0.002, decay, 0.0, release, gm: false) * 0.45
}
