# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "partial_keys",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Additive keys: sixteen harmonics with levels falling by a brightness ratio, each decaying on its own (the high ones first), so notes start bright and mellow as they ring (additive; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:additive, :harmonics, :keys],
  options: { patch: :partial_keys }
inputs midi: :notes
param :bright, (0.05..0.95).at(0.62), description: "Each harmonic's level over the one below it"
param :odd, (0.0..1.0).at(0.3), description: "Even harmonics turned down: 0 all harmonics, 1 odd ones only (hollow)"
param :decay, (0.05..10.0).at(3.0), description: "The fundamental's decay in seconds (harmonic n decays n^0.8 times faster)"
param :release, (0.01..5.0).at(0.4), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  v.hz.harmonics([1.0 * v.env(0.002, decay / 1.0, 0, release, gm: false), bright ** 1 * (1 - odd) * v.env(0.002, decay / 1.7411011265922482, 0, release, gm: false), bright ** 2 * v.env(0.002, decay / 2.4082246852806923, 0, release, gm: false), bright ** 3 * (1 - odd) * v.env(0.002, decay / 3.0314331330207964, 0, release, gm: false), bright ** 4 * v.env(0.002, decay / 3.623898318388478, 0, release, gm: false), bright ** 5 * (1 - odd) * v.env(0.002, decay / 4.192962712629476, 0, release, gm: false), bright ** 6 * v.env(0.002, decay / 4.743276393803367, 0, release, gm: false), bright ** 7 * (1 - odd) * v.env(0.002, decay / 5.278031643091578, 0, release, gm: false), bright ** 8 * v.env(0.002, decay / 5.799546134795289, 0, release, gm: false), bright ** 9 * (1 - odd) * v.env(0.002, decay / 16.db, 0, release, gm: false), bright ** 10 * v.env(0.002, decay / 6.809483127522302, 0, release, gm: false), bright ** 11 * (1 - odd) * v.env(0.002, decay / 7.30037210271847, 0, release, gm: false), bright ** 12 * v.env(0.002, decay / 7.783137122039472, 0, release, gm: false), bright ** 13 * (1 - odd) * v.env(0.002, decay / 8.258523872989459, 0, release, gm: false), bright ** 14 * v.env(0.002, decay / 8.727161387290321, 0, release, gm: false), bright ** 15 * (1 - odd) * v.env(0.002, decay / 9.18958683997628, 0, release, gm: false)]) * 0.31
}
