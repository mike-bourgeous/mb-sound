# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "ambient_drone",
  kind: :synth,
  saved: "2026-10-13T22:45:32Z",
  mb_sound: "0.12.0.usegit (af720dbd)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :drone from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :drone, space: 0.5, wear: 0.0, tune: -7.0, spread: 0.7 }
inputs :midi

synth(midi, voices: 3, seed: drawn_seed(900450186894289455)) { |v|
  sig = v.freq
  sig2 = 0.05.hz.lfo.square.sample_hold
  sig3 = 0.05.hz.lfo.square.sample_hold
  sig4 = 0.05.hz.lfo.square.sample_hold
  sig5 = 0.05.hz.lfo.square.sample_hold
  sig6 = 0.05.hz.lfo.square.sample_hold
  sig7 = 0.05.hz.lfo.square.sample_hold
  stereo(((sig * 1.0 + sig2.smooth(20.0).at(-0.15..0.15)).tone.sine * 0.5 + (sig * 1.4983070768766815 + 0.31 + sig3.smooth(20.0).at(-0.2..0.2)).tone.sine * 0.3 + (sig * 2.0 - 0.17 + sig4.smooth(20.0).at(-0.25..0.25)).tone.sine * 0.18).softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6), ((sig * 1.0 + sig5.smooth(20.0).at(-0.2..0.2)).tone.sine * 0.5 + (sig * 1.4983070768766815 + 0.31 + sig6.smooth(20.0).at(-0.2..0.2)).tone.sine * 0.3 + (sig * 2.0 - 0.22000000000000003 + sig7.smooth(20.0).at(-0.25..0.25)).tone.sine * 0.18).softclip(0.8, 0.95).filter(:lowpass, cutoff: 900, quality: 0.6)) * 1.0 * 0.18 * v.env(3.0, 0, 1, 4.0, curve: :gentle, gm: false)
}
