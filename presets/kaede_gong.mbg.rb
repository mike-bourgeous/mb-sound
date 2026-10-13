# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kaede_gong",
  kind: :synth,
  saved: "2026-10-13T09:30:52Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kaede_rowntree.rb",
  options: { patch: :gong, wear: 0.0 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, e-piano, harp)"

voice = synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |n|
  hit = n.trigger
  fall = adsr(0, 4, 0, 0, trigger: hit, curve: :linear)
  f = 55.0 * 2 ** ((n.number - 38) / 12.0)
  swell = n.env(2.2, 7, 0, 3, curve: :swell, gm: false)
  osc = noise
  sig = 0.7.hz.lfo.square.sample_hold
  air = osc.filter(:bandpass, cutoff: sig.smooth(1.4285714285714286).at(2400..5200), quality: 1.5) * swell * 0.07
  low = (hit.ping(f * 1.0 * (1 + fall * 0.05), decay: 24.0) * 0.6 + hit.ping(f * 1.47 * (1 + fall * 0.05), decay: 17.777777777777775) * 0.48 + hit.ping(f * 2.02 * (1 + fall * 0.05), decay: 14.117647058823529) * 0.39999999999999997 + hit.ping(f * 2.51 * (1 + fall * 0.05), decay: 11.707317073170733) * 0.34285714285714286 + hit.ping(f * 2.97 * (1 + fall * 0.05), decay: 10.0) * 0.3 + hit.ping(f * 3.58 * (1 + fall * 0.05), decay: 8.727272727272727) * 0.26666666666666666 + hit.ping(f * 4.23 * (1 + fall * 0.05), decay: 7.741935483870969) * 0.24 + hit.ping(f * 5.06 * (1 + fall * 0.05), decay: 6.9565217391304355) * 0.21818181818181817 + hit.ping(f * 5.91 * (1 + fall * 0.05), decay: 6.315789473684211) * 0.19999999999999998 + hit.ping(f * 6.8 * (1 + fall * 0.05), decay: 5.783132530120481) * 0.1846153846153846).filter(:highpass, cutoff: 38, quality: 0.6) * 0.12
  stereo(low, low) + air.pan(0.2)
}
voice.and_then(silence(20)) + voice.reverb(room_size: 1.0, decay: 10, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
