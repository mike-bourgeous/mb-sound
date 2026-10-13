# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_reese",
  kind: :synth,
  saved: "2026-10-13T09:59:55Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/kez_volta.rb",
  options: { patch: :reese, grit: 0.25, echo: 0.4 }
inputs :midi
param :cutoff, 2400.0, range: 150.0..8000.0, description: "Reese lowpass center in Hz"

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  pitch = v.hz.glide(0.035, legato: true)
  saws = pitch.unison(6, detune: 0.32, spread: 0.5) { |p, _i|
    p.saw
  }
  lfo = 2 ** v.lfo(2.bars, shape: :sine, depth: 0.8)
  amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
  ((saws.lp4(cutoff * lfo, resonance: 0.25) * 2.2).softclip(0.35, 0.95) * amp).filter(:highpass, cutoff: 150, quality: 0.7).filter(:highpass, cutoff: 150, quality: 0.7)
}
