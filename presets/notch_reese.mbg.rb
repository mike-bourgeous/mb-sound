# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "notch_reese",
  kind: :synth,
  saved: "2026-11-22T04:52:34Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "A Reese that aches instead of snarls: two saws beating about once a second plus an octave, driven into a softclipper before a dark lp4, a low cut, and a notch swinging over three bars.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :bass, :mono],
  options: { patch: :notch_reese }
inputs midi: :notes
param :cutoff, (100.0..8000.0).at(800.0), description: "lp4 cutoff in Hz (after the softclipper)"
param :drive, (0.5..20.0).at(5.0), description: "Gain into the softclipper"

(synth(midi, voices: 1) { |v|
  f = v.hz.glide(60.ms)
  (f.transpose(-0.09).saw + f.transpose(0.09).saw + f.transpose(12.04).saw * 0.3) * v.amp_env(0.06, 0.2, 0.9, 0.2)
} * drive).softclip(0.25, 0.8).lp4(cutoff, resonance: 0.18).filter(:highpass, cutoff: 120).filter(:highpass, cutoff: 120).filter(:notch, cutoff: 3.bars.hz.lfo.at(500..1400), quality: 1.6)
