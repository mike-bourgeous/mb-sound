# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 9,
  name: "fit_space",
  kind: :effect,
  saved: "2026-11-06T21:14:15Z",
  mb_sound: "0.12.0.usegit (4b053d5)",
  from: "bin/save_presets.rb",
  description: "A big space (T60 5.6 s at 125 Hz to 2.6 s at 8 kHz), the FDN fitted by reverb_match to a synthesized impulse",
  tags: [:fitted, :huge, :long]
inputs input: :audio
param :mix, (0.0..1.0).at(0.3), description: "Dry/wet mix (equal power)"

input.blend(mix, curve: :power) { |s|
  s.reverb(room_size: 0.9, decay: 5.3732, damping: 0.8067, predelay: 0.02025, wet: 1.0, dry: 0, seed: 1, level: 0.3751, extra_time: 8.4, output_channels: 2).peq({ 500 => [0.5.db, 1], 1000 => [-0.7.db, 1], 2000 => [-0.54.db, 1], 4000 => [-0.95.db, 1], 8000 => [2.02.db, 1] }).width(0.959)
}
