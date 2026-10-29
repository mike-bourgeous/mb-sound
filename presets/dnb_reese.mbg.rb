# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 5,
  name: "dnb_reese",
  kind: :synth,
  saved: "2026-10-28T06:21:20Z",
  mb_sound: "0.12.0.usegit (b7efc32b)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :reese from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm).",
  options: { patch: :reese, attack: nil, decay: nil, release: nil, grit: nil, echo: nil, drop: nil }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(2400.0), description: "Lowpass cutoff in Hz (reese 2400 around its LFO, sub 110, neuro 600 and pluck 500 under their envelopes, pad 2600)"
param :resonance, (0.0..1.0).at(0.25), description: "Reese lowpass resonance 0..1 (0.25)"
param :drive, (0.5..8.0).at(2.2), description: "Reese drive into the softclipper (2.2)"
param :glide, (0.0..0.5).at(0.035), description: "Reese legato glide in seconds (0.035)"

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  pitch = v.hz.glide(glide, legato: true)
  saws = pitch.unison(6, detune: 0.32, spread: 0.5) { |p, _i|
    p.saw
  }
  lfo = 2 ** v.lfo(2.bars, shape: :sine, depth: 0.8)
  amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
  ((saws.lp4(cutoff * lfo, resonance: resonance) * drive).softclip(0.35, 0.95) * amp).filter(:highpass, cutoff: 150, quality: 0.7).filter(:highpass, cutoff: 150, quality: 0.7)
}
