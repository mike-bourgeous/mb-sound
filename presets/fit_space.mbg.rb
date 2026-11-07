# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 9,
  name: "fit_space",
  kind: :effect,
  saved: "2026-11-07T00:13:16Z",
  mb_sound: "0.12.0.usegit (b636733)",
  from: "bin/save_presets.rb",
  description: "A big space (T60 5.6 s at 125 Hz to 2.6 s at 8 kHz), the FDN fitted by reverb_match to a synthesized impulse",
  tags: [:fitted, :huge, :long]
inputs input: :audio
param :mix, (0.0..1.0).at(0.3), description: "Dry/wet mix (equal power)"

input.blend(mix, curve: :power) { |s|
  s.reverb(room_size: 0.9, decay: 5.3665, damping: 0.8032, channels: 16, predelay: 0.02104, wet: 1.0, dry: 0, seed: 1, level: 0.3821, extra_time: 8.4, output_channels: 2).peq({ 125 => [-0.78.db, 1], 1000 => [-0.8.db, 1], 2000 => [-0.26.db, 1], 4000 => [-0.83.db, 1], 8000 => [2.56.db, 1] }).width(0.959)
}
