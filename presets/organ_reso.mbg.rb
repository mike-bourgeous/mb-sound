# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "organ_reso",
  kind: :synth,
  saved: "2026-10-23T05:22:59Z",
  mb_sound: "0.12.0.usegit (c51d07cc)",
  from: "bin/synths/wave_voices.rb",
  description: "Wave voice :organ_reso: Resonant organ for chords and comping: drawbar harmonics plus SYNTH 3 an octave up through a resonant, nearly closed 4-pole that blips open on each key; grit 0..1 holds the oscillators at the Ensoniq DOC's 38.46 kHz (from bin/synths/wave_voices.rb: the research-sq80 prototype voice of 2026-10-06, rebuilt from library nodes in protos-1, 2026-10-23)",
  options: { patch: :organ_reso, voices: nil }
inputs midi: :notes
param :grit, 0.0, range: 0.0..1.0, description: "Grit 0..1: the oscillators held at the DOC's 38.46 kHz, aliasing (1: the prototype's grit)"
param :cutoff, 900.0, range: 20..10000, description: "Filter cutoff in Hz at C4 before the envelope (digibrass 500, organ_reso 900, square_bass 150)"
param :reso, 0.6401, range: 0.0..1.0, description: "lp4 resonance 0..1 (digibrass 0.37, organ_reso 0.64, square_bass 0.48)"

synth(midi, voices: 8) { |v|
  f = v.hz
  mix = (f.wavetable(wavetable_of([1, 0.8, 0.6, 0.5, 0, 0.35, 0, 0.3])) * 0.7 + f.transpose(11.96).wavetable(wavetable_of([1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1])) * 0.3).decimate(38461.5, mix: grit)
  fenv = v.env([[1.0, 0.005], [0.3, 0.15], [0.2, 0.3], [0.0, 0.3]], release_at: 3, curve: 0).no_velocity
  cut = cutoff * 2 ** ((v.number - 60) / 12.0 + fenv * 1.5)
  amp = v.env([[1.0, 0.004], [1.0, 0.01], [1.0, 0.01], [0.0, 0.25]], release_at: 3, curve: 0, sensitivity: 0.5..1.0)
  out = (mix * 0.35).lp4(cut, resonance: reso, drive: 2.0, tuning: :hardware) * amp
  out * 1.49
}
