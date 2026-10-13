# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "funk_beat",
  kind: :synth,
  saved: "2026-10-13T16:48:36Z",
  mb_sound: "0.12.0.usegit (5f5c51c6)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :beat from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :beat, dub: 0.0, keep: 0.82 }
inputs :midi

sig = tr808(midi, only: [:kick, :snare, :closed_hat, :open_hat], velocity_curve: :midi, kick: { tune: 56, decay: 0.32, tone: 0.25 }, snare: { tune: 210, decay: 0.16, tone: 0.55, snappy: 0.75 }, closed_hat: { decay: 0.035, tone: 0.5 }, open_hat: { decay: 0.22 }, seed: drawn_seed(900450186894289455))
lfo = 1.bar.hz.lfo.triangle
(sig * 0.55 + sig.formant(:a, :o, :u, morph: lfo * 0.32000000000000006 + 0.7, shift: lfo * -4.0, width: 1.6) * 0.7).softclip(0.7, 0.95) * 2.0
