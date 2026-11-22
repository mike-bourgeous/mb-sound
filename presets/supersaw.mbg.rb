# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "supersaw",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Supersaw: seven detuned saws spread across the stereo field, a gentle lowpass, for chords and washes (stereo) (unison; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:unison, :saw, :chords, :pad, :wide, :trance],
  options: { patch: :supersaw }
inputs midi: :notes
param :detune, (0.0..1.0).at(0.18), description: "Detune of the outer saws in semitones"
param :spread, (0.0..1.0).at(0.8), description: "Stereo spread of the copies"
param :mix, (0.0..2.0).at(0.8), description: "Side copies' level against the center one"
param :cutoff, (200.0..18000.0).at(6000.0), description: "Lowpass cutoff in Hz"
param :attack, (0.001..5.0).at(0.02), description: "Attack in seconds"
param :release, (0.01..8.0).at(0.5), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  sig = v.hz.unison(7, detune: detune, spread: spread, mix: mix, detune_mode: :interp)
  fx = sig.saw.lp4(cutoff, resonance: 0.05)
  fx * v.env(attack, 0.4, 0.85, release, gm: false) * 0.25
}
