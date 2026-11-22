# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 11,
  name: "ladder_lead",
  kind: :synth,
  saved: "2026-11-13T02:06:33Z",
  mb_sound: "0.12.0.usegit (3314d3a)",
  from: "bin/synths/library_voices.rb",
  description: "Ladder lead: two saws 9 cents apart and a square an octave down through the four-pole ladder (lp4), its cutoff opened by an envelope on each note; mono with glide (subtractive (lp4 ladder); from bin/synths/library_voices.rb, library-voices-1, 2026-11-13)",
  tags: [:subtractive, :lp4, :ladder, :analog, :lead],
  options: { patch: :ladder_lead }
inputs midi: :notes
param :cutoff, (40.0..12000.0).at(700.0), description: "Cutoff in Hz at C4 before the envelope (keytracked half)"
param :reso, (0.0..1.0).at(0.35), description: "Resonance 0..1"
param :fenv, (0.0..6.0).at(3.0), description: "Envelope amount in octaves"
param :fdecay, (0.01..5.0).at(0.5), description: "Envelope decay in seconds"
param :glide, (0.0..1.0).at(0.06), description: "Glide between legato notes in seconds"

synth(midi, voices: 1) { |v|
  sig = v.hz.glide(glide, legato: true)
  ((sig.saw + sig.transpose(0.09).saw + sig.transpose(-12).square * 0.6) * 0.35).lp4((cutoff * 2 ** ((v.number - 60) / 24.0 + fenv * v.env(0.003, fdecay, 0.15, 0.2, gm: false).legato)).aclip(20, 18000), resonance: reso) * v.env(0.003, 0.4, 0.8, 0.15, gm: false).legato * 1.0
}
