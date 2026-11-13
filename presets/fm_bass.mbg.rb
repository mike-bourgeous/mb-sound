# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "fm_bass",
  kind: :synth,
  saved: "2026-11-13T02:06:32Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Feedback FM bass: a sine operator fed back into its own phase, turning saw-like as the feedback envelope opens on each note, with a sine an octave down (FM operator feedback; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:fm, :feedback, :dx, :bass],
  options: { patch: :fm_bass }
inputs midi: :notes
param :feedback, (0.0..1.8).at(1.2), description: "Operator feedback in radians at the strike (0: a sine; past 1.5: buzzy)"
param :hold, (0.0..1.0).at(0.3), description: "Feedback kept while the note holds, as a share of the strike's"
param :fdecay, (0.01..5.0).at(0.25), description: "Seconds the feedback takes to fall to its held share"
param :sub, (0.0..1.0).at(0.5), description: "Level of the sine an octave down"
param :release, (0.005..2.0).at(0.08), description: "Release in seconds"

synth(midi, voices: 2) { |v|
  sig = v.hz
  (sig.fm_feedback((feedback * v.env(0.001, fdecay, hold, release, gm: false).no_velocity).radians) + sig.transpose(-12).sine * sub) * v.env(0.002, 0.6, 0.8, release, gm: false) * 0.6
}.hp1(20)
