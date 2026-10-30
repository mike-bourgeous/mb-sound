# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 7,
  name: "init",
  kind: :synth,
  saved: "2026-10-30T04:11:42Z",
  mb_sound: "0.12.0.usegit (e04cc138)",
  from: "bin/synths/init_voice.rb",
  description: "Init: the blank voice to start a sound from: two morphing oscillators (sine, triangle, square, saw), a mix, optional FM, AM, and hard sync of OSC2 by OSC1 (each off by default), a four-pole lowpass with its envelope, an amp ADSR, and glide; every number a knob (from bin/synths/init_voice.rb, sound-design-2, 2026-10-29)",
  options: { patch: :init, voices: 8 }
inputs midi: :notes
param :wave1, (0.0..1.0).at(1.0), description: "OSC1 wave: sine 0, triangle 0.33, square 0.67, saw 1 (morphs between)"
param :wave2, (0.0..1.0).at(1.0), description: "OSC2 wave: sine 0, triangle 0.33, square 0.67, saw 1 (morphs between)"
param :tune2, (-24.0..24.0).at(0.07), description: "OSC2 pitch in semitones from OSC1 (0.07: 7 cents; sweep it with sync on)"
param :mix, (0.0..1.0).at(0.5), description: "OSC1 0 .. OSC2 1"
param :fm, (0.0..4.0).at(0.0), description: "FM index: OSC1 modulates OSC2's frequency (DX7-style: the same sidebands at every note), 0: off"
param :am, (0.0..1.0).at(0.0), description: "AM: OSC1 multiplies OSC2 (1: ring modulation), 0: off"
param :sync, (0..1).at(0), description: "Hard sync of OSC2 to OSC1, 0 off or 1 on (read when the voice builds: turning it rebuilds the track)"
param :cutoff, (20.0..20000.0).at(1200.0), description: "Filter cutoff in Hz at C4 before the envelope (keytracked half)"
param :reso, (0.0..1.0).at(0.2), description: "lp4 resonance 0..1"
param :fenv, (0.0..6.0).at(2.0), description: "Filter envelope amount in octaves"
param :fdecay, (0.001..10.0).at(0.4), description: "Filter envelope decay in seconds"
param :attack, (0.001..10.0).at(0.005), description: "Amplitude attack in seconds"
param :decay, (0.001..10.0).at(0.3), description: "Amplitude decay in seconds"
param :sustain, (0.0..1.0).at(0.7), description: "Amplitude sustain level 0..1"
param :release, (0.001..10.0).at(0.3), description: "Amplitude release in seconds (the filter envelope's too)"
param :glide, (0.0..2.0).at(0.0), description: "Glide between notes in seconds, 0: off"

synth(midi, voices: 8) { |v|
  f = v.hz.glide(glide)
  osc1 = f.wavetable(:basic_norm, scan: wave1).named("osc1")
  osc2 = f.transpose(tune2).wavetable(:basic_norm, scan: wave2).fm(osc1 * v.freq * fm).sync(osc1, enabled: sync).gain(1 - am + osc1 * am).named("osc2")
  oscs = osc1 * (1 - mix) + osc2 * mix
  cut = cutoff * 2 ** ((v.number - 60) / 24.0) * v.filter_env(0.002, fdecay, 0, release, depth: fenv)
  amp = v.amp_env(attack, decay, sustain, release)
  oscs.lp4(cut, resonance: reso) * amp * 1.8
}
