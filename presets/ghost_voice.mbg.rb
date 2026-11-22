# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "ghost_voice",
  kind: :synth,
  saved: "2026-11-22T04:52:33Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "A ghost of a voice: two saws (one a hair sharp, each with its own vibrato) through alto formants morphing ah-oh-oo over a bar; variant 1 is mostly breath (noise in narrow bands at the note and its 2nd and 3rd harmonics, about 3 dB over the saws) with a slower attack.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :formant, :vocal, :breath, :lead, :variant],
  options: { patch: :ghost_voice }
inputs midi: :notes
param :variant, (0.0..1.0).at(0.0), description: "Version: 0 the first (v1), 1 the second (v2); in between fades every setting that differs"

sig = 0.45 ** variant * 1.0
sig2 = 1.7500000000000002 ** variant * 0.04
sig3 = 1.2 ** variant * 0.25
synth(midi, voices: 1) { |v|
  p = v.hz.glide(110.ms)
  osc = noise
  air = osc.filter(:highpass, cutoff: 1500)
  f = v.freq
  osc2 = noise
  osc3 = noise
  osc4 = noise
  osc5 = noise
  breath = osc2.filter(:bandpass, cutoff: f, quality: 14) * 5 + osc3.filter(:bandpass, cutoff: f * 2, quality: 14) * 3 + osc4.filter(:bandpass, cutoff: f * 3, quality: 12) * 2 + osc5.filter(:highpass, cutoff: 2500) * 0.06
  saws = p.fm(5.3.hz.at(2.2)).saw + p.transpose(0.11).fm(5.3.hz.at(2.2)).saw * 0.6
  src = saws * sig + air * ((variant * -1 + 1) ** 0.5 * 0.05) + breath * (variant ** 0.5 * 2)
  src.formant(:a, :o, :u, morph: 1.bar.hz.lfo.at(0.0..1.0), voice: :alto) * v.amp_env(sig2, 0.2, 0.85, sig3)
} * (2.db ** variant * 1.0)
