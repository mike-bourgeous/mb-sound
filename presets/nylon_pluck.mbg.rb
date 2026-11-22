# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "nylon_pluck",
  kind: :synth,
  saved: "2026-11-13T02:28:30Z",
  mb_sound: "0.12.0.usegit (fa5909f)",
  from: "bin/synths/library_voices.rb",
  description: "Plucked string: a feedback loop one period long, excited by a noise pick and damped in the loop (bin/synths/pluck.rb's string), dry (Karplus-Strong (feedback loop); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:karplus, :feedback, :string, :guitar, :pluck],
  options: { patch: :nylon_pluck }
inputs midi: :notes

synth(midi, voices: 6) { |v|
  fx = v.velocity.aease(:quad_out, out: 0.0..1.0)
  sig = v.freq
  sig2 = v.period
  fx2 = sig.aease(:smoothstep, in: 707.1067811865474..1414.213562373095)
  sig3 = 1 - fx
  sig4 = fx2 + (1 - fx2) * sig3
  osc = noise
  osc2 = noise
  sig5 = osc2.filter(:lowpass, cutoff: 1500 * 7.0.constant ** fx, quality: 0.6) * v.env(0, 0.008, 0, 0.008, gm: false, sensitivity: 0.3..1.0) * (((1200.0 / sig) ** 0.531508495181978).aclip(1, 100) * 2.8.db) * ((1 - fx2) * fx ** 0.5)
  sig6 = 10.constant ** (-1.0 / sig)
  sig7 = sig * (6.0 - 4.0 * v.cc(1, range: 0.0..1.0, name: "Damping", description: "Darkens the string (loop lowpass)"))
  (osc.filter(:lowpass, cutoff: sig * 13.0.constant ** fx, quality: 0.6) * v.env(0, 0, 1, 0, gate: false, gm: false, hold: sig2 * 1.0, sensitivity: 0.3..1.0) * (fx2 + (1 - fx2) * sig3 ** 0.5)).feedback { |fb, input|
    line = fb + input
    d = line.delay(sig2, smooth: false, max_delay: 0.08)
    s = ((d + d.delay(1.samples)) * (sig6 * 0.5)).filter(:lowpass, cutoff: sig7, quality: 0.7071067811865476)
    s + sig5
  } * v.amp_env([[0, sig2 * sig4, 0, :exp], [1, sig2 * (sig4 + 1), 0, :exp], [0, 0.08]]) * 4 * 0.5
}.filter(:highpass, cutoff: 20, quality: 0.7071)
