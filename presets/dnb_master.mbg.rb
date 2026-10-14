# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 3,
  name: "dnb_master",
  kind: :effect,
  saved: "2026-10-14T03:18:39Z",
  mb_sound: "0.12.0.usegit (796a1077)",
  from: "bin/synths/dnb.rb",
  description: "Effect :dnb_master from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm)."
inputs :input
param :air, 20.0, range: 20.0..400.0, description: "Highpass in Hz"
param :drive, 11.0, range: 0.0..24.0, description: "Gain in dB into the clipper and limiter"

(input.filter(:highpass, cutoff: air, quality: 0.7).compress(threshold: -14.db, ratio: 2, knee: 6, attack: 0.01, release: 0.12) * 10 ** (drive / 20)).softclip(0.6, 1.0).limit(ceiling: -0.5.db, release: 0.06)
