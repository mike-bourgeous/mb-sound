# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "sq80_prime_bass",
  kind: :synth,
  saved: "2026-10-17T05:43:23Z",
  mb_sound: "0.12.0.usegit (504ed966)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :prime_bass: A bass: PRIME an octave down and SYNTH 3 without vibrato, input drive, a snappy filter envelope that velocity opens. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :prime_bass, voices: nil, drive_mode: nil, drive: nil, chop: nil, flutter: nil, second_release: false }
inputs :midi
param :cutoff, 220.0, range: 20..10000, description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, 0.5, range: 0.0..1.0, description: "Resonance 0..1, CC 71 moves it (classic 0.4)"

sq80(midi, :prime_bass, cutoff: cutoff, reso: reso, seed: drawn_seed(900450186894289455))
