# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "funk_keys",
  kind: :synth,
  saved: "2026-10-30T04:10:58Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/funk.rb",
  description: "Funk patch :keys from bin/synths/funk.rb, first made by Tiko Marvell, a fictional funk / neo-soul live looper, for the set \"Loop Church\" (bin/songs/loop_church.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-looper).",
  options: { patch: :keys, dub: nil, keep: nil, bite: nil, cutoff: nil, glide: nil, echo: nil, attack: nil, release: nil }
inputs midi: :notes
param :body, (0.0..2.0).at(0.25), description: "Keys body FM index (0.25)"
param :decay, (0.01..10.0).at(3.0), description: "Decay in seconds (bass 0.5, keys 3, clav 0.12)"

synth(midi, voices: 8, retrigger: :string) { |v|
  sig = v.hz
  body_mod = sig.sine.free(true) * v.fm_env(0, 2.0, 0, 0.5) * body
  body_osc = sig.sine.free(true).pm(body_mod)
  tine_mod = sig.transpose(3.807354922057604.oct).sine.free(true) * v.fm_env(0, 0.3, 0, 0.1) * v.velocity * 0.18
  tine_osc = sig.sine.free(true).pm(tine_mod)
  (body_osc + tine_osc * 0.6) * v.amp_env(0.002, decay, 0, 0.25) * 0.35
}.softclip(0.8, 0.95).filter(:highpass, cutoff: 160).pan(4.5.hz.lfo.at(0.35)) * 1
