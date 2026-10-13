# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_neuro",
  kind: :synth,
  saved: "2026-10-13T10:00:03Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :neuro, cutoff: 2400.0, echo: 0.4 }
inputs :midi
param :grit, 0.25, range: 0.0..1.0, description: "Neuro crusher wet share 0..1"

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  pitch = v.hz.glide(0.02, legato: true)
  src = pitch.unison(3, detune: 0.18) { |p, _i|
    p.saw
  } + pitch.transpose(12).square * 0.4
  jump = 2 ** v.lfo(1.n16, shape: :square, depth: 1.3)
  ladder = src.diode(600 * jump * 2 ** (v.env(0.002, 0.12, 0.6, 0.04, gm: false).legato * 2), resonance: 0.55)
  talk = ladder.formant(:o, :a, :i, voice: :bass, morph: v.lfo(1.n8, shape: :triangle, unipolar: true) * 2)
  crushed = (talk * 3).softclip(0.3, 0.95).decimate(v.freq * 24, mix: grit)
  env = v.env(0.002, 0.12, 0.6, 0.04, gm: false).legato
  crushed * env
}.squeeze(:default, depth: 0.7, split: [250, 2500]).filter(:highpass, cutoff: 140, quality: 0.7)
