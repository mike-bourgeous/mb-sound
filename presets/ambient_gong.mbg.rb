# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "ambient_gong",
  kind: :synth,
  saved: "2026-10-13T18:58:16Z",
  mb_sound: "0.12.0.usegit (01f36fe8)",
  from: "bin/synths/ambient.rb",
  description: "Ambient patch :gong from bin/synths/ambient.rb, first made by Kaede Rowntree, a fictional piano tuner turned field recordist, for the soundscape \"Tin Roof, Slow River\" (bin/songs/tin_roof.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-zen).",
  options: { patch: :gong, wear: 0.0 }
inputs :midi
param :space, 0.5, range: 0.0..1.0, description: "Room level 0..1 (bowls, rin, gong, koto, harp)"
param :tune, 0.0, range: -24.0..12.0, description: "Gong shimmer tuning in semitones (the shimmer partials and their noise band)"

sig = 2 ** (tune / 12.0)
voice = synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |n|
  hit = n.trigger
  fall = adsr(0, 4, 0, 0, trigger: hit, curve: :linear)
  f = 55.0 * 2 ** ((n.number - 38) / 12.0)
  swell = n.env(2.2, 7, 0, 3, curve: :swell, gm: false)
  osc = noise
  sig2 = 0.7.hz.lfo.square.sample_hold
  band = osc.filter(:bandpass, cutoff: sig2.smooth(1.4285714285714286).at(2400..5200) * sig, quality: 1.5)
  top = f * sig
  l = band.ping(top * 29.099999999999998 * (1 + fall * 0.05 * 0.6), decay: 1.148733053788381) + band.ping(top * 35.7130766541782 * (1 + fall * 0.05 * 1.2111456), decay: 1.036936063946216) + band.ping(top * 43.819919805739936 * (1 + fall * 0.05 * 1.0222912000000002), decay: 0.9361163335524968) + band.ping(top * 53.756187662795156 * (1 + fall * 0.05 * 0.8334368000000001), decay: 0.8451842229612515) + band.ping(top * 65.93262155349585 * (1 + fall * 0.05 * 0.6445824000000001), decay: 0.7631597202351307) + band.ping(top * 76.19092573456665 * (1 + fall * 0.05 * 1.2557280000000004), decay: 0.7099274795944917) + band.ping(top * 93.4907336690104 * (1 + fall * 0.05 * 1.0668736000000003), decay: 0.640886802177834) + band.ping(top * 114.69536486139891 * (1 + fall * 0.05 * 0.8780192), decay: 0.578618984214491)
  r = band.ping(top * 33.22808832649805 * (1 + fall * 0.05 * 0.9055728000000001), decay: 1.0750110641000725) + band.ping(top * 40.757677249770914 * (1 + fall * 0.05 * 0.7167184000000001), decay: 0.97064606717962) + band.ping(top * 47.087409686802715 * (1 + fall * 0.05 * 1.3278640000000002), decay: 0.9030529424979288) + band.ping(top * 57.78357500052922 * (1 + fall * 0.05 * 1.1390096), decay: 0.8151985685049313) + band.ping(top * 70.89490610355091 * (1 + fall * 0.05 * 0.9501552000000004), decay: 0.7359665846493756) + band.ping(top * 86.96393168532218 * (1 + fall * 0.05 * 0.7613008000000001), decay: 0.6645015970903764) + band.ping(top * 100.4540607371625 * (1 + fall * 0.05 * 1.3724464000000005), decay: 0.6182752525826966) + band.ping(top * 123.27882500000001 * (1 + fall * 0.05 * 1.1835920000000002), decay: 0.5581120110415778)
  noise_part = (band * 0.6324555320336759 * swell * 0.07).pan(0.2)
  air = noise_part + stereo(l * 0.85 + r * 0.15000000000000002, l * 0.15000000000000002 + r * 0.85) * (swell * 0.07 * 0.0035612047833060148)
  low = (hit.ping(f * 1.0 * (1 + fall * 0.05), decay: 24.0) * 0.6 + hit.ping(f * 1.47 * (1 + fall * 0.05), decay: 17.777777777777775) * 0.48 + hit.ping(f * 2.02 * (1 + fall * 0.05), decay: 14.117647058823529) * 0.39999999999999997 + hit.ping(f * 2.51 * (1 + fall * 0.05), decay: 11.707317073170733) * 0.34285714285714286 + hit.ping(f * 2.97 * (1 + fall * 0.05), decay: 10.0) * 0.3 + hit.ping(f * 3.58 * (1 + fall * 0.05), decay: 8.727272727272727) * 0.26666666666666666 + hit.ping(f * 4.23 * (1 + fall * 0.05), decay: 7.741935483870969) * 0.24 + hit.ping(f * 5.06 * (1 + fall * 0.05), decay: 6.9565217391304355) * 0.21818181818181817 + hit.ping(f * 5.91 * (1 + fall * 0.05), decay: 6.315789473684211) * 0.19999999999999998 + hit.ping(f * 6.8 * (1 + fall * 0.05), decay: 5.783132530120481) * 0.1846153846153846).filter(:highpass, cutoff: 38, quality: 0.6) * 0.12
  stereo(low, low) + air
}
voice.and_then(silence(20)) + voice.reverb(room_size: 1.0, decay: 10, damping: 0.55, predelay: 0.03, dry: 0, wet: 1) * space
