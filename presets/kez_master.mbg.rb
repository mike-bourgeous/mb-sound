# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "kez_master",
  kind: :effect,
  saved: "2026-10-13T09:31:44Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/kez_volta.rb"
inputs :input
param :air, 20.0, range: 20.0..400.0, description: "Highpass in Hz"

(input.filter(:highpass, cutoff: air, quality: 0.7).compress(threshold: -14.db, ratio: 2, knee: 6, attack: 0.01, release: 0.12) * 11.0.db).softclip(0.6, 1.0).limit(ceiling: -0.5.db, release: 0.06)
