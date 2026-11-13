# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "breath_vowel",
  kind: :synth,
  saved: "2026-11-13T06:46:33Z",
  mb_sound: "0.12.0.usegit (366bde7)",
  from: "bin/synths/library_voices.rb",
  description: "Breathy vowel: a saw and breath through vowel formants, the vowel morphing from oo through oh and ah to ee on a knob; the breath is noise in narrow bands at the note's harmonics (20 cents wide at the fundamental to 120 at the 16th), a puff at each note settling lower while it holds; vibrato and glide (formant; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:formant, :vowel, :vocal, :breath, :lead],
  options: { patch: :breath_vowel }
inputs midi: :notes
param :vowel, (0.0..1.0).at(0.45), description: "Vowel: 0 oo, 0.33 oh, 0.67 ah, 1 ee (morphs between)"
param :breath, (0.0..1.0).at(0.35), description: "Breath level at the start of a note"
param :hold, (0.0..1.0).at(0.3), description: "Breath kept while the note holds, as a share of the start's"
param :vibrato, (0.0..1.0).at(0.25), description: "Vibrato depth in semitones (it fades in over half a second)"
param :attack, (0.001..3.0).at(0.06), description: "Attack in seconds"
param :release, (0.01..5.0).at(0.3), description: "Release in seconds"
param :glide, (0.0..1.0).at(0.05), description: "Glide between legato notes in seconds"

synth(midi, voices: 4) { |v|
  sig = v.hz.glide(glide, legato: true).vibrato(5.3, depth: vibrato * v.env(0.5, 0, 1, 0.1, gm: false).no_velocity)
  (sig.saw + noise.bandpass_series(sig.freq, count: 16, quality: [86.56, 76.94, 68.16, 60.53, 53.6, 47.69, 42.23, 37.55, 33.29, 29.54, 26.23, 23.27, 20.63, 18.32, 16.26, 14.43], normalize: true) * breath * (hold + (1 - hold) * v.env(0.005, 0.25, 0, 0.1, gm: false).no_velocity) * 4).formant(:u, :o, :a, :i, morph: vowel) * v.env(attack, 0.3, 0.9, release, gm: false) * 0.22
}
