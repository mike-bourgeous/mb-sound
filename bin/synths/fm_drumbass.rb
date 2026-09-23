#!/usr/bin/env ruby

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |input|
  s = MB::Sound.synth(input, osc_count: 1) { |midi, idx|
    # A note about the original code: the old drumbass incremented each voice
    # by 16 semitones, but voice 0 was normal and there was only one voice.
    # But, GraphVoice resets oscillator frequencies, except one note that
    # remained a constant frequency.

    # FIXME: the new version behaves differently on every event while the old
    # one sounds the same every time.  This does not appear to be caused by
    # oscillator sync.

    cenv = midi.env(0, 0.005, 0.5, 0.005).named('C Envelope').db(30)
    cenv2 = midi.env(0, 0.01, 0.5, 0.01).named('C Mod Envelope').db(60)
    c = cenv * midi.tone.at(1).fm(cenv2 * MB::Sound::C3.at(1)).named('C')

    denv = midi.env(0, 0.005, 0.0, 0.005).named('D Envelope').db(50)
    d = denv * (midi.frequency * 0.9996 - 0.22).tone.at(1).named('D')

    eenv = midi.env(0, 2, 0, 2).named('E Envelope').db
    e = eenv * midi.tone.at(1).fm(c * 4810 + d * 500).named('E')

    fenv = midi.env(0, 2, 0, 2).named('F Envelope').db
    f = fenv * midi.tone.at(1).fm(e * 250).named('F')
  }

  s.softclip(0.8, 0.95)
}
