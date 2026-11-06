# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 9,
  name: "fit_hall",
  kind: :effect,
  saved: "2026-11-06T21:14:15Z",
  mb_sound: "0.12.0.usegit (4b053d5)",
  from: "bin/save_presets.rb",
  description: "A warm hall (T60 3.0 s at 125 Hz to 1.0 s at 8 kHz), the FDN fitted by reverb_match to a synthesized impulse",
  tags: [:fitted, :big, :warm]
inputs input: :audio
param :mix, (0.0..1.0).at(0.3), description: "Dry/wet mix (equal power)"

input.blend(mix, curve: :power) { |s|
  s.reverb(room_size: 0.9, decay: 2.583, lowpass: 8786.6, predelay: 0.00225, wet: 1.0, dry: 0, seed: 1, level: 0.6581, extra_time: 4.5, output_channels: 2).peq({ 125 => [3.58.db, 1], 250 => [1.9.db, 1], 500 => [0.9.db, 1], 1000 => [-1.25.db, 1], 2000 => [-1.34.db, 1], 4000 => [-1.71.db, 1], 8000 => [-2.07.db, 1] }).width(0.882)
}
