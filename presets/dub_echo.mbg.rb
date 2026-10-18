# mb-sound rack document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 4,
  name: "dub_echo",
  kind: :effect,
  rack: :arack,
  saved: "2026-10-18T02:42:55Z",
  mb_sound: "0.12.0.usegit (ab05b5fc)",
  from: "bin/songs/rack_demo.rb",
  description: "Rack :dub_echo from bin/songs/rack_demo.rb (racks-r2, 2026-10-17): dub echoes of the input, knob :space (echo level and feedback) and :tone (the echoes' lowpass, swinging slowly around the knob)"
inputs sig: :audio
outputs :audio
knob :space, 0.35, description: "Echo level and feedback 0..1"
knob :tone, 2400.0, range: 600.0..8000.0, curve: :exp, unit: "Hz", description: "Echo lowpass"

sig + sig.delay(3.n16, feedback: space * 0.7, wet: space, dry: 0).filter(:lowpass, cutoff: tone.mod(0.13.hz.lfo, depth: 0.15))
