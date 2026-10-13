# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kaede_bowl",
  kind: :synth,
  saved: "2026-10-13T09:30:42Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kaede_rowntree.rb",
  options: { patch: :bowl, wear: 0.0 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, e-piano, harp)"

sig = (synth(midi, voices: 6) { |v|
  sig2 = v.trigger
  sig3 = v.freq * 1.0
  sig2.ping(sig3 * 1.0, decay: 24.0) * 1.0 + sig2.ping(sig3 * 1.0 + 0.7, decay: 19.200000000000003) * 0.7 + (sig2.ping(sig3 * 2.77, decay: 11.040000000000001) * 0.45 + sig2.ping(sig3 * 2.77 + 1.7236021786828828, decay: 8.832) * 0.315) + (sig2.ping(sig3 * 5.15, decay: 6.0) * 0.22 + sig2.ping(sig3 * 5.15 + 2.9198172576634094, decay: 4.800000000000001) * 0.154) + (sig2.ping(sig3 * 8.1, decay: 3.5999999999999996) * 0.1 + sig2.ping(sig3 * 8.1 + 4.244006386229115, decay: 2.88) * 0.06999999999999999)
} * 0.12).pan(0)
sig.and_then(silence(18)) + sig.reverb(room_size: 0.9, decay: 9, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
