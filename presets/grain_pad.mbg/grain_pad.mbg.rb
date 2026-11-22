# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "grain_pad",
  kind: :synth,
  saved: "2026-11-13T02:12:13Z",
  mb_sound: "0.12.0.usegit (db7df14)",
  from: "bin/synths/library_voices.rb",
  description: "Grain pad: a cloud of short grains read from a two-second tone bounced from oscillators (an A3 triangle with upper partials slightly off their harmonics, slowly beating), each grain tuned to the note, spread in stereo (granular; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:granular, :grains, :cloud, :pad],
  options: { patch: :grain_pad }
inputs midi: :notes
param :position, (0.0..1.0).at(0.35), description: "Where in the source tone the grains read (0..1)"
param :spread, (0.0..0.5).at(0.15), description: "Random spread of the read position (0..1 of the source)"
param :density, (1.0..120.0).at(30.0), description: "Grains per second per note"
param :size, (0.01..1.0).at(0.15), description: "Grain length in seconds"
param :detune, (0.0..1.0).at(0.08), description: "Random detune per grain in semitones"
param :attack, (0.001..8.0).at(0.6), description: "Attack in seconds"
param :release, (0.01..8.0).at(1.5), description: "Release in seconds"
asset "assets/grain_source.flac", sha256: "3f47e73fe641ac9fed3cdb0bba33b63ff0253b0b1ab82d5d200d0704f3f77dec"

synth(midi, voices: 6) { |v|
  Sample["assets/grain_source.flac"].grains(freq: v.freq, trigger: v.trigger, max_grains: 16, density: density, size: size, position: position, spread: spread, pitch_spread: detune, pan_spread: 0.7) * v.env(attack, 0.5, 0.9, release, gm: false) * 0.38
}
