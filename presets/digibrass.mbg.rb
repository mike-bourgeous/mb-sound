# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "digibrass",
  kind: :synth,
  saved: "2026-10-30T04:11:49Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/wave_voices.rb",
  description: "Wave voice :digibrass: Digital brass for stabs and swells: a saw and a bright formant wave 7 cents apart plus a noise-and-chirp attack, a resonant 4-pole opening 3.5 octaves on each note, slight vibrato; grit 0..1 holds the oscillators at the Ensoniq DOC's 38.46 kHz (from bin/synths/wave_voices.rb: the research-sq80 prototype voice of 2026-10-06, rebuilt from library nodes in protos-1, 2026-10-23)",
  options: { patch: :digibrass, voices: nil }
inputs midi: :notes
param :grit, (0.0..1.0).at(0.0), description: "Grit 0..1: the oscillators held at the DOC's 38.46 kHz, aliasing (1: the prototype's grit)"
param :cutoff, (20.0..10000.0).at(500.0), description: "Filter cutoff in Hz at C4 before the envelope (digibrass 500, organ_reso 900, square_bass 150)"
param :reso, (0.0..1.0).at(0.3717), description: "lp4 resonance 0..1 (digibrass 0.37, organ_reso 0.5, square_bass 0.48)"

synth(midi, voices: 8, seed: drawn_seed(900450186894289455)) { |v|
  f = v.hz.vibrato(5.5, depth: 0.0346)
  hiss = noise.filter(:lowpass, cutoff: 3300, quality: 0.5) * v.env(0, 0.04, 0, 0.04, curve: [0, 58, 58]).no_velocity
  sweep = v.env(0, 0.04, 0, 0.04, curve: 0).no_velocity * 720 + 1080
  chirp = sweep.tone.sine.reset(v.trigger) * v.env(0, 0.012, 0, 0.012, curve: [0, 52, 52]).no_velocity
  mix = (f.wavetable(wavetable_of(:saw)).with_phase(0.5) * -0.6 + f.transpose(0.07).wavetable(wavetable_of([0.6, 0.3, 0.202, 0.163, 0.174, 0.266, 0.455, 0.672, 0.767, 0.657, 0.424, 0.216, 0.1, 0.056, 0.042, 0.038, 0.035, 0.033, 0.032, 0.03, 0.029, 0.027, 0.026, 0.025, 0.024, 0.023, 0.022, 0.021, 0.021, 0.02, 0.019, 0.019, 0.018, 0.018, 0.017, 0.017, 0.016, 0.016, 0.015, 0.015])) * 0.5).decimate(38461.5, mix: grit) + (hiss * 1.6 + chirp * 0.8) * 0.5
  fenv = v.env([[1.0, 0.03], [0.55, 0.25], [0.35, 0.8], [0.0, 0.4]], release_at: 3, curve: 0).no_velocity
  cut = cutoff * 2 ** ((v.number - 60) / 24.0 + fenv * 3.5)
  amp = v.env([[1.0, 0.01], [0.85, 0.2], [0.75, 0.3], [0.0, 0.45]], release_at: 3, curve: 0, sensitivity: 0.5..1.0)
  out = (mix * 0.35).lp4(cut, resonance: reso, drive: 1.5, tuning: :hardware) * amp
  out * 2.58
}
