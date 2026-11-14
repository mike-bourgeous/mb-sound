# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "pwm_strings",
  kind: :synth,
  saved: "2026-11-13T02:06:32Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "PWM strings: two pulses a few cents apart, their widths drifting on slow LFOs, through a gentle keytracked lowpass and a Juno-style chorus (stereo) (PWM; from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:pwm, :pulse, :strings, :pad, :analog],
  options: { patch: :pwm_strings }
inputs midi: :notes
param :width, (0.05..0.95).at(0.5), description: "Pulse width at the LFOs' center (0.5: square)"
param :depth, (0.0..0.45).at(0.3), description: "How far the LFOs move the widths"
param :rate, (0.05..8.0).at(0.6), description: "LFO rate in Hz (the second pulse's LFO runs 0.73 times as fast)"
param :cutoff, (200.0..12000.0).at(2400.0), description: "Lowpass cutoff in Hz at C4 (keytracked half)"
param :attack, (0.001..5.0).at(0.35), description: "Attack in seconds"
param :release, (0.01..8.0).at(0.9), description: "Release in seconds"

synth(midi, voices: 8) { |v|
  sig = v.hz
  ((sig.pwm(width + depth * rate.tone.sine.lfo).square + sig.transpose(0.08).pwm(width + depth * (rate * 0.73).tone.sine.lfo.with_phase(0.3)).square) * 0.5).lp4(cutoff * 2 ** ((v.number - 60) / 24.0), resonance: 0.05) * v.env(attack, 0.5, 0.85, release, gm: false) * 0.18
}.chorus(:juno2)
