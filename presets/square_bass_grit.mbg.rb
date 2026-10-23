# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "square_bass_grit",
  kind: :synth,
  saved: "2026-10-23T01:31:47Z",
  mb_sound: "0.12.0.usegit (5ea4a46f)",
  from: "bin/synths/wave_voices.rb",
  description: "Wave voice :square_bass (grit: 8-bit 256-sample tables held at the DOC rate): Plucked square bass for bass lines: a square plus a saw an octave down, a resonant 4-pole plucked 4 octaves open by a fast envelope. (from bin/synths/wave_voices.rb: the research-sq80 prototype voice of 2026-10-06, rebuilt from library nodes in protos-1, 2026-10-23)",
  options: { patch: :square_bass, grit: true, voices: nil }
inputs midi: :notes
param :cutoff, 150.0, range: 20..10000, description: "Filter cutoff in Hz at C4 before the envelope (digibrass 500, organ_reso 900, square_bass 150)"
param :reso, 0.481, range: 0.0..1.0, description: "lp4 resonance 0..1 (digibrass 0.37, organ_reso 0.64, square_bass 0.48)"

synth(midi, voices: 4) { |v|
  f = v.hz
  mix = (f.wavetable(wavetable_of(:square, size: 256, mips: false, interpolation: :none)).aquantize(1r/127) * 0.8 + f.transpose(-11.97).wavetable(wavetable_of(:saw, size: 256, mips: false, interpolation: :none)).with_phase(0.5).aquantize(1r/127) * -0.5).decimate(38461.5)
  fenv = v.env([[1.0, 0.002], [0.15, 0.18], [0.0, 0.2], [0.0, 0.1]], release_at: 3, curve: 0).no_velocity
  cut = cutoff * 2 ** ((v.number - 60) / 40.0 + fenv * 4.0)
  amp = v.env([[1.0, 0.002], [0.8, 0.3], [0.7, 0.3], [0.0, 0.12]], release_at: 3, curve: 0, sensitivity: 0.5..1.0)
  out = (mix * 0.35).lp4(cut, resonance: reso, drive: 2.5, tuning: :hardware) * amp
  out * 3.08
}
