# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "bowed_glass",
  kind: :synth,
  saved: "2026-11-13T02:06:34Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Bowed glass: the glass resonator's modes excited by soft noise for as long as the key is held (a bow instead of a strike), swelling in and ringing out on release (modal resonator (sustained); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:modal, :resonator, :bowed, :pad],
  options: { patch: :bowed_glass }
inputs midi: :notes
param :bow, (0.0..4.0).at(1.0), description: "Bow pressure (the noise's level)"
param :tone, (200.0..16000.0).at(3000.0), description: "Lowpass on the bow noise in Hz (brighter excites higher modes)"
param :decay, (0.2..12.0).at(3.0), description: "Seconds the glass rings to -60 dB once the bow lets go (the preset's 8: a real glass)"
param :attack, (0.001..5.0).at(0.4), description: "Bow attack in seconds"
param :release, (0.01..5.0).at(0.3), description: "Bow release in seconds (the glass rings on after it)"

synth(midi, voices: 6) { |v|
  (noise.filter(:lowpass, cutoff: tone, quality: 0.7) * bow * 0.01 * v.env(attack, 0.0, 1.0, release, gm: false)).resonate(:glass, v.freq, decay: decay) * 0.55
}
