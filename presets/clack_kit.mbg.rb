# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 13,
  name: "clack_kit",
  kind: :synth,
  saved: "2026-11-22T04:52:34Z",
  mb_sound: "0.12.0.usegit (8f21c2a)",
  from: "bin/synths/halftime.rb",
  description: "A half-time kit: a small kick, a woody FM clack for a snare, a clap that gives it weight, an FM rim click, metal hats, a noise shaker, and a ride (GM notes); variant 1 weighs the clap 2.5 dB more.  From bin/synths/halftime.rb (n109-1, 2026-11-22), first made by Kez Volta, a fictional modern EDM / UK drum & bass producer-DJ, for the half-time B-side \"N109\" (bin/songs/n109.rb) in the persona panel's third round (2026-11-09/10).",
  tags: [:halftime, :dnb, :n109, :drums, :fm, :variant],
  options: { patch: :clack_kit }
inputs midi: :notes
param :variant, (0.0..1.0).at(0.0), description: "Version: 0 the first (v1), 1 the second (v2); in between fades every setting that differs"

kit(midi, clap: { weight: 1.3333333333333333 ** variant * 0.45 }) {
    voice(:kick, tune: 78) { |h|
      (h.body(h.tune, decay: 0.3, sweep: 2.6) * 1.3 + h.click(0.25)).filter(:highpass, cutoff: 70, quality: 0.7).softclip(0.6, 1.0)
    }
    # A clack more than a snare: woody FM knock, short noise, a bit of body.
    voice(:snare) { |h|
      (h.fm(820, ratio: 1.83, index: 3.0, decay: 0.07, index_decay: 0.02) * 0.7 +
        h.body(235, decay: 0.16, sweep: 1.4) * 0.8 +
        h.noise(decay: 0.22, highpass: 1500).filter(:lowpass, cutoff: 9000) * 0.5).softclip(0.5, 1.0)
    }
    # The weight that turns the clack into a snare when it goes two-step.
    voice(:clap, weight: 0.45) { |h|
      (h.body(196, decay: 0.24, sweep: 1.5) * 0.7 + h.noise(decay: 0.38, highpass: 1900).filter(:lowpass, cutoff: 10000) * 0.5).softclip(0.5, 1.0) * h.weight
    }
    voice(:rim) { |h| h.fm(1400, ratio: 2.41, index: 1.2, decay: 0.025, index_decay: 0.008) * 0.8 }
    voice(:hat, decay: 0.03) { |h| h.metal.filter(:highpass, cutoff: 9000).filter(:lowpass, cutoff: 13000) * h.env(h.decay) * 9 }
    voice(:open_hat, decay: 0.09) { |h| h.noise(decay: 0.09, highpass: 6000).filter(:lowpass, cutoff: 11000) * 0.5 }
    voice(:ride, decay: 0.2) { |h| h.metal.filter(:bandpass, cutoff: 6200, quality: 1.2) * h.env(h.decay) * 5 }
  }
