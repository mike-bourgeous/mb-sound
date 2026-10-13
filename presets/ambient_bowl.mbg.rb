# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "ambient_bowl",
  kind: :synth,
  saved: "2026-10-13T14:43:10Z",
  mb_sound: "0.12.0.usegit (d86d4454)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :bowl from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :bowl, wear: 0.0 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"

sig = (synth(midi, voices: 6) { |v|
  sig2 = v.trigger
  sig3 = v.freq * 1.0
  sig2.ping(sig3 * 1.0, decay: 24.0) * 1.0 + sig2.ping(sig3 * 1.0 + 0.7, decay: 19.200000000000003) * 0.7 + (sig2.ping(sig3 * 2.77, decay: 11.040000000000001) * 0.45 + sig2.ping(sig3 * 2.77 + 1.7236021786828828, decay: 8.832) * 0.315) + (sig2.ping(sig3 * 5.15, decay: 6.0) * 0.22 + sig2.ping(sig3 * 5.15 + 2.9198172576634094, decay: 4.800000000000001) * 0.154) + (sig2.ping(sig3 * 8.1, decay: 3.5999999999999996) * 0.1 + sig2.ping(sig3 * 8.1 + 4.244006386229115, decay: 2.88) * 0.06999999999999999)
} * 0.12).pan(0)
sig.and_then(silence(18)) + sig.reverb(room_size: 0.9, decay: 9, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
