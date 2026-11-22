# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "window_rain",
  kind: :synth,
  saved: "2026-11-22T04:52:34Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "Rain on the glass: drops ringing at random pitches, a dark noise bed, wandering across the stereo field, with its own hall and dub echo; variant 1 is 3 dB down and wetter (outside the window).  It ignores notes.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :texture, :weather, :drops, :stereo, :variant],
  options: { patch: :window_rain }
inputs midi: :notes
param :variant, (0.0..1.0).at(0.0), description: "Version: 0 the first (v1), 1 the second (v2); in between fades every setting that differs"
param :density, (1.0..1000.0).at(160.0), description: "Drops per second"

sig = dust(density, range: 0.05..1, seed: 1)
osc = noise
osc2 = noise
sig2 = drift(1)
sig3 = (sig.ping(osc.sample_hold(sig).at(2500..7000), decay: 0.02) * 0.12 + osc2.lp4(3000).at(-30.db)).pan(sig2) * (-3.db ** variant * 1.0)
sig3 + (sig3 * (4.466835921509631 ** variant * -18.db)).filter(:highpass, cutoff: 400).reverb(:hall, mix: 1) + (sig3 * (variant ** 0.5 * -12.db)).ping_pong(3.n16, feedback: 0.5).filter(:lowpass, cutoff: 2400).filter(:highpass, cutoff: 400)
