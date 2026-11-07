# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 9,
  name: "dnb_reese",
  kind: :synth,
  saved: "2026-11-07T04:27:15Z",
  mb_sound: "0.12.0.usegit (debcdfb)",
  from: "bin/synths/dnb.rb",
  description: "Drum & bass patch :reese from bin/synths/dnb.rb, first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the song \"Tunnel Vision\" (bin/songs/tunnel_vision.rb) in the persona panel experiment of 2026-10-13 (research branch research-persona-edm). Its cutoff breathes on a tempo LFO (lfo_depth octaves either side, one cycle every lfo_bars bars; both turn live); lfo_depth: 0 leaves the cutoff to cutoff alone, which takes a number, a knob, or a tween (preset :dnb_reese, midi: clip, lfo_depth: 0, cutoff: tween([300.hz, 3000.hz], 4.bars)).  slope: 12 swaps lp4 (24 dB/octave) for a 2-pole lowpass on the same resonance knob, chosen when it builds (preset :dnb_reese, midi: clip, slope: 12); low_cut (two highpasses, 150 Hz) turns live, 0 letting the fundamental through.",
  options: { patch: :reese, attack: nil, decay: nil, release: nil, grit: nil, echo: nil, drop: nil }
inputs midi: :notes
param :cutoff, (20.0..10000.0).at(2400.0), description: "Lowpass cutoff in Hz (reese 2400 around its LFO, sub 110, neuro 600 and pluck 500 under their envelopes, pad 2600)"
param :lfo_depth, (0.0..1.0).at(0.8), description: "Reese cutoff LFO depth in octaves either side of the cutoff (0.8; 0 for no LFO)"
param :lfo_bars, (0.25..16.0).at(2.0), description: "Reese cutoff LFO cycle length in bars, locked to the timeline while steady (2)"
param :resonance, (0.0..1.0).at(0.25), description: "Reese lowpass resonance 0..1 (0.25; lp4's knob at both slopes)"
param :slope, 24, range: [24, 12], description: "Reese lowpass slope in dB/octave: 24 (lp4) or 12 (a 2-pole on the same resonance knob; read when the voice builds)"
param :low_cut, (0.0..500.0).at(150.0), description: "Reese low cut in Hz: two highpasses under the sub (150; 0 lets the fundamental through)"
param :drive, (0.5..8.0).at(2.2), description: "Reese drive into the softclipper (2.2)"
param :glide, (0.0..0.5).at(0.035), description: "Reese legato glide in seconds (0.035)"

synth(midi, voices: 1, seed: drawn_seed(900450186894289455)) { |v|
  pitch = v.hz.glide(glide, legato: true)
  saws = pitch.unison(6, detune: 0.32, spread: 0.5) { |p, _i|
    p.saw
  }
  lfo = 2 ** v.lfo(lfo_bars.bars, shape: :sine, depth: lfo_depth)
  amp = v.env(0.004, 0.25, 0.85, 0.06, gm: false).legato
  reese = (saws.filter(:lowpass, cutoff: cutoff * lfo, resonance: resonance, slope: slope) * drive).softclip(0.35, 0.95) * amp
  reese.filter(:highpass, cutoff: low_cut, quality: 0.7).filter(:highpass, cutoff: low_cut, quality: 0.7)
}
