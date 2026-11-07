# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 9,
  name: "fit_room",
  kind: :effect,
  saved: "2026-11-06T21:14:15Z",
  mb_sound: "0.12.0.usegit (4b053d5)",
  from: "bin/save_presets.rb",
  description: "A small dark room (T60 0.92 s at 125 Hz to 0.30 s at 8 kHz), the FDN fitted by reverb_match to a synthesized impulse",
  tags: [:fitted, :small, :dark]
inputs input: :audio
param :mix, (0.0..1.0).at(0.3), description: "Dry/wet mix (equal power)"

input.blend(mix, curve: :power) { |s|
  s.reverb(room_size: 0.9, decay: 0.8317, damping: 0.7656, predelay: 0.0, wet: 1.0, dry: 0, seed: 1, level: 0.9996, extra_time: 1.4, output_channels: 2).peq({ 125 => [7.52.db, 1], 250 => [4.1.db, 1], 500 => [1.63.db, 1], 1000 => [1.13.db, 1], 4000 => [-2.69.db, 1], 8000 => [-11.87.db, 1] }).width(0.773)
}
