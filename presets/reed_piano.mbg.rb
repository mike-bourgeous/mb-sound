# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "reed_piano",
  kind: :synth,
  saved: "2026-10-30T04:11:36Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/electric_pianos.rb",
  description: "Reed piano (Wurlitzer-style FM) from bin/synths/electric_pianos.rb, made in patches-2 (2026-10-13) as a closer-to-physical alternative to the jungle keys (jungle_keys_voice in bin/synths/jungle.rb, from the persona panel experiment).",
  options: { patch: :reed, amp: nil, tremolo: 0.3 }
inputs midi: :notes
param :bark, (0.0..2.0).at(1.0), description: "Velocity-driven bark (FM index and pickup growl) scale"
param :pickup, (0.0..3.0).at(1.0), description: "Pickup drive scale (follows velocity; the reed also grows on low keys; default tine 0.5, reed 1.0)"
param :decay, (0.1..20.0).at(2.6), description: "Amplitude decay in seconds (tine 4.5, reed 2.6)"
param :release, (0.01..5.0).at(0.18), description: "Release in seconds (tine 0.35, reed 0.18)"

synth(midi, voices: 8, retrigger: :string) { |v|
  f = v.hz
  sig = v.velocity
  vel2 = sig * sig
  index = v.env(0, 0.8, 0.25, 0.3, gm: false).no_velocity * (vel2 * (0.22 * bark) + 0.04)
  reed = f.sine.free(true).pm(f.transpose(12).sine.free(true) * index)
  amp = v.amp_env(0.002, decay, 0, release, curve: [12, 30, 40])
  drive = sig * 2 ** ((60 - v.number).aclip(0, nil) * 0.125) * pickup * (2.5 * bark) + 1
  (reed * amp * drive).softclip(0.4, 0.95) * 0.625
}.peq(1000.hz => [4.db, 1.2]).filter(:highpass, cutoff: 60, quality: 0.7) * (0.7 + 5.6.hz.lfo.at(0..0.3)) * 0.4
