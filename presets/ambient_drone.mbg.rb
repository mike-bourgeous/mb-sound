# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "ambient_drone",
  kind: :synth,
  saved: "2026-10-17T05:42:51Z",
  mb_sound: "0.12.0.usegit (504ed966)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :drone from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :drone, space: 0.5, wear: 0.6, tune: -7.0, spread: 0.7 }
inputs :midi

synth(midi, voices: 3, seed: drawn_seed(900450186894289455)) { |v|
  sig = v.freq
  sig2 = drift(0.05, range: -0.15..0.15, smooth: :smoothstep, from: 0.0)
  sig3 = drift(0.05, range: -0.2..0.2, smooth: :smoothstep, from: 0.0)
  sig4 = drift(0.05, range: -0.25..0.25, smooth: :smoothstep, from: 0.0)
  sig5 = drift(0.05, range: -0.2..0.2, smooth: :smoothstep, from: 0.0)
  sig6 = drift(0.05, range: -0.2..0.2, smooth: :smoothstep, from: 0.0)
  sig7 = drift(0.05, range: -0.25..0.25, smooth: :smoothstep, from: 0.0)
  stereo(((sig * 1.0 + sig2).tone.sine * 0.5 + (sig * 1.4983070768766815 + 0.31 + sig3).tone.sine * 0.3 + (sig * 2.0 - 0.17 + sig4).tone.sine * 0.18).softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6), ((sig * 1.0 + sig5).tone.sine * 0.5 + (sig * 1.4983070768766815 + 0.31 + sig6).tone.sine * 0.3 + (sig * 2.0 - 0.22000000000000003 + sig7).tone.sine * 0.18).softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6)) * 1.0 * 0.18 * v.env(3.0, 0, 1, 4.0, curve: :gentle, gm: false)
}
