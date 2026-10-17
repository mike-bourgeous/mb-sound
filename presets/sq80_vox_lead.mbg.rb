# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "sq80_vox_lead",
  kind: :synth,
  saved: "2026-10-17T17:19:08Z",
  mb_sound: "0.12.0.usegit (47598381)",
  from: "bin/synths/sq80_voice.rb",
  description: "SQ-80 voice :vox_lead: A vowel lead: the formant wave up front with a slightly flat SYNTH 3, input drive, deeper delayed vibrato. (from bin/synths/sq80_voice.rb: the voice since 2026-10-07, patches since sq80-lib-1, 2026-10-17)",
  options: { patch: :vox_lead, voices: nil, drive_mode: nil, drive: nil, chop: nil, second_release: false }
inputs midi: :notes
param :cutoff, 1400.0, range: 20..10000, description: "Filter cutoff in Hz before modulation (classic 500)"
param :reso, 0.25, range: 0.0..1.0, description: "Resonance 0..1, CC 71 moves it (classic 0.4)"
param :flutter, 0.5, range: 0.0..4.0, description: "Poly pressure flutter depth in octaves, 0: off (classic 1.0)"

sq80(midi, :vox_lead, cutoff: cutoff, reso: reso, flutter: flutter, seed: drawn_seed(900450186894289455))
