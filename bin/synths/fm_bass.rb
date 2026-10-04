#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A very rough approximation of Solid Bass or Lately Bass from the classic
# Yamaha FM synthesizers.

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The FM bass graph for MIDI +input+ (a MIDI file, a JACK port name, or nil
  # for live MIDI).  Also used by bin/audio_load_check.rb as a reference
  # load.  See MidiMethods#synth for +:parameter_map+.  +:oversample+ is the
  # oversampling factor (1 for none).
  def self.fm_bass(input, parameter_map: true, oversample: 4)
    s = synth(input, parameter_map: parameter_map) { |midi|
      base = midi.number.named('Note number').smooth(0.1).freq.named('Base freq')
      base2x = (base * 2).named('Base 2x')
      mod = midi.cc(1, range: 1.0..2.0)

      # TODO: True FM/PM feedback instead of a duplicate copy of the oscillator
      cenv = midi.env(0, 0.2, 0.0, 0.1).named('cenv').db(30)
      c = cenv * base2x.tone.complex_sine.at(1).pm(cenv * mod * base2x.tone.at(1))

      denv = midi.env(0, 0.3, 0.0, 0.35).named('denv').db(30)
      d = denv * (base2x * 0.9996 - 0.22).tone.complex_sine.at(1).named('d')

      # FIXME: sounds are too quiet below ~80 velocity
      eenv = midi.env(0, 2, 0.7, 0.5).named('eenv').db(10)
      e = eenv * base.tone.complex_sine.at(1).pm(mod * (c + d)).named('e')

      fenv = midi.amp_env(0, 2, 0.8, 0.5).named('fenv').db(10)
      f = fenv * base.tone.complex_sine.at(1).pm(e * mod).named('f')

      f.real * 0.125
    }

    # Reduce aliasing noise
    s = s.softclip(0.8, 0.95).filter(15000.hz.lowpass)
    s = s.oversample(oversample, mode: :libsamplerate_fastest) if oversample > 1

    s + s.delay(seconds: 0.1)
  end

  if main_script?(__FILE__)
    synth_script(
      oversample: [4, Integer, 'Oversampling factor (1 for none; less aliasing, more CPU)', 1..8],
    ) { |input, p| fm_bass(input, oversample: p.oversample) }
  end
end
