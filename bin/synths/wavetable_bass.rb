#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Wavetable- and waveshaping-based monophonic bass synth.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# CC 1 picks the oscillator's wavetable, CC 2 drives the shaper, and CC 4
# picks the shaper's wavetable.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid wavebass.flac

require 'bundler/setup'
require 'mb-util'
require 'mb-sound'

# Each side's oscillators are detuned by a random amount up to this (the
# old constants called it 5 cents, but it was 0.05 octaves)
DETUNE = 0.05.oct
PORTAMENTO_TIME = 0.1 # TODO: control with MIDI CC 5

MB::Sound.synth_script { |midi|
  # Tables saved from MB::Sound::Wavetable.load_wavetable('sounds/drums.flac',
  # slices: 10) (and synth0.flac), which takes several seconds to analyze.
  MB::U.headline('Loading wavetables...')
  synthwave = MB::Sound::Wavetable.sort(
    MB::Sound::Wavetable.normalize(
      MB::Sound::Wavetable.load_wavetable('sounds/drums_wavetable_10.flac')
    )
  )
  shaperwave = MB::Sound::Wavetable.sort(
    MB::Sound::Wavetable.normalize(
      MB::Sound::Wavetable.load_wavetable('sounds/synth0_wavetable_10.flac')
    )
  )

  MB::U.headline('Building synth...')

  # One mono synth per side, each with its own random detuning (repeatable:
  # drawn from the synth lane's seed)
  side = -> {
    midi.synth(voices: 1) { |v|
      detune = -> { DETUNE * MB::Sound.root_rng.rand(-1.0..1.0) }

      cc1 = v.cc(1, name: 'Wavetable').filter(:lowpass, cutoff: 10, quality: 0.5)
      cc2 = v.cc(2, range: 1..10, name: 'Drive').filter(:lowpass, cutoff: 10, quality: 0.5)
      cc4 = v.cc(4, name: 'Shaper').filter(:lowpass, cutoff: 10, quality: 0.5)

      # Portamento as in the old version: a lowpass filter on the frequency
      # (fast at first, then settling), starting at 440 Hz so the first
      # note swoops down from A4.  This matched the old pitch track within
      # 0.05 semitones on average; a smoothstep glide(100.ms) was up to
      # 6.6 semitones off during the swoop.
      portamento = ->(pitch) {
        pitch.glide(0, from: 440.hz).freq
          .filter(:lowpass, cutoff: 1.0 / PORTAMENTO_TIME, quality: 0.5)
          .tone.reset(v.trigger)
      }

      a = portamento.(v.hz.transpose(detune.()))
        .ramp.at(2).named('A Phase')
        .wavetable(wavetable: synthwave, number: cc1).named('A Wavetable')
        .filter(:lowpass, cutoff: 5000, quality: 0.4).named('A Filter')

      b = portamento.(v.hz.transpose(detune.()))
        .triangle.at(0.5).named('B')

      # The old envelope measured: linear in velocity (0.1..1) and close to
      # straight lines in time (energy within 0.1 dB of the old smoothstep
      # one; the :analog amp_env was 5.6 dB weaker at velocity 64, which
      # drove the shaper less and lost the growl)
      env = v.env(0.003, 0.05, 0.5, 0.3, curve: :linear, sensitivity: 0.1..1)

      sum = (a + b) * cc2 * env

      (sum.softclip * 2)
        .wavetable(wavetable: shaperwave, number: cc4)
    }.filter(:highpass, cutoff: 10, quality: 0.7)
  }

  s1 = side.()
  s2 = side.()

  l = s1.filter(:lowpass, cutoff: 15000, quality: 0.25).softclip
  r = s2.filter(:lowpass, cutoff: 15000, quality: 0.25).softclip

  MB::U.headline('Begin play!')

  [l, r]
}
