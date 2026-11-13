# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "breath_vowel",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Breathy vowel: a saw and breath noise through vowel formants, the vowel morphing from oo through oh and ah to ee on a knob, with delayed vibrato and glide (formant; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:formant, :vowel, :vocal, :breath, :lead],
  options: { patch: :breath_vowel }
inputs midi: :notes
param :vowel, (0.0..1.0).at(0.45), description: "Vowel: 0 oo, 0.33 oh, 0.67 ah, 1 ee (morphs between)"
param :breath, (0.0..1.0).at(0.35), description: "Breath noise level"
param :vibrato, (0.0..1.0).at(0.25), description: "Vibrato depth in semitones (it fades in over half a second)"
param :attack, (0.001..3.0).at(0.06), description: "Attack in seconds"
param :release, (0.01..5.0).at(0.3), description: "Release in seconds"
param :glide, (0.0..1.0).at(0.05), description: "Glide between legato notes in seconds"

synth(midi, voices: 4) { |v|
  (v.hz.glide(glide, legato: true).vibrato(5.3, depth: vibrato * v.env(0.5, 0, 1, 0.1, gm: false).no_velocity).saw + noise * breath * 1.5).formant(:u, :o, :a, :i, morph: vowel) * v.env(attack, 0.3, 0.9, release, gm: false) * 0.22
}
