# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "tine_piano",
  kind: :synth,
  saved: "2026-10-14T02:45:58Z",
  mb_sound: "0.12.0.usegit (94c421d7)",
  from: "bin/synths/electric_pianos.rb",
  description: "Tine piano (Rhodes-style FM) from bin/synths/electric_pianos.rb, made in patches-2 (2026-10-13) as a closer-to-physical alternative to the jungle keys (jungle_keys_voice in bin/synths/jungle.rb, from the persona panel experiment).",
  options: { patch: :tine, tremolo: 0.3 }
inputs :midi
param :bark, 1.0, range: 0.0..2.0, description: "Velocity-driven bark (FM index and pickup growl) scale"
param :pickup, 0.5, range: 0.0..3.0, description: "Pickup drive scale (follows velocity; the reed also grows on low keys; default tine 0.5, reed 1.0)"
param :amp, 1.0, range: 0.25..8.0, description: "Tine amp drive: 1 clean, 1.5 a warm edge, 2 crunch, 4-8 broken up (quiet notes keep their level; default tine 1, crunch 4)"

((synth(midi, voices: 8, retrigger: :string) { |v|
  f = v.hz
  sig = v.velocity
  vel2 = sig * sig
  index = v.env(0, 1.2, 0.1, 0.4, gm: false).no_velocity * (vel2 * (0.3 * bark) + 0.03)
  body = f.sine.free(true).pm(f.sine.free(true) * index)
  bell = f.sine.free(true).pm(f.transpose(45.68825906469125).sine.free(true) * v.env(0, 0.12, 0, 0.05, gm: false).no_velocity * (sig * 0.25))
  bar = f.transpose(12).sine.free(true) * v.env(0.001, 1.4, 0, 0.3, gm: false).no_velocity * 0.12
  x = (body + bell * 0.3 + bar) * v.amp_env(0.001, 4.5, 0, 0.35, curve: [12, 40, 40])
  x * (x * (sig * pickup * (0.5 * bark)) + 1)
}.filter(:highpass, cutoff: 30, quality: 0.7) * (amp * 0.18)).softclip(0.8, 0.95) * (1.8 / amp)).pan(4.8.hz.lfo.at(0.3))
