# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "nev_reese",
  kind: :synth,
  saved: "2026-10-13T10:00:36Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/skylark_junction.rb",
  options: { patch: :reese, cutoff: 16000.0, echo: 0.3 }
inputs :midi

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  p = v.hz.glide(0.06, legato: true)
  saws = p.unison(2, detune: 16.cents, phase: 0.0) { |c, _i|
    c.saw
  }
  breath = 1.bar.hz.transpose(-12).lfo.at(260..700)
  body = saws.lp4(breath, resonance: 0.2)
  (body * 0.9 + p.sine * 0.6) * v.env(0.02, 0.3, 0.9, 0.15, gm: false).legato
}.softclip(0.5, 0.95) * 0.32
