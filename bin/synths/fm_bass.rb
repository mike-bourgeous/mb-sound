#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A very rough approximation of Solid Bass or Lately Bass from the classic
# Yamaha FM synthesizers.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# CC 1 (the mod wheel) deepens the phase modulation.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid bass.flac

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The FM bass graph for MIDI +midi+ (a Notes such as a synth script's
  # `midi`, a MIDI filename, or another source; see MidiMethods#synth).
  # Also used by bin/audio_load_check.rb as a reference load.
  # +:oversample+ is the oversampling factor (1 for none).
  #
  # The envelopes are DX-style (straight lines in dB, the old `.db(N)`
  # envelopes): curves of -N dB rising, and for falls the share of the N dB
  # they cover (see Envelope); sustain levels and velocity ranges are the
  # old ones converted the same way.
  def self.fm_bass(midi, oversample: 4)
    s = synth(midi, voices: 4) { |v|
      # Every note glides from the last note played (polyphonic glide,
      # Synth's default glide_mode: :last), as the old GraphVoice version
      # did: it moved idle voices' note numbers to each new note, smoothed
      # over 0.1 s.
      base = v.hz.glide(100.ms)
      base2x = base.transpose(1.oct)
      mod = v.cc(1, range: 1.0..2.0, name: 'FM depth')

      # TODO: True FM/PM feedback instead of a duplicate copy of the oscillator
      cenv = v.fm_env(0, 0.2, 0, 0.1)
      c = cenv * base2x.complex_sine.at(1).pm(cenv * mod * base2x.at(1))

      denv = v.fm_env(0, 0.3, 0, 0.35)
      d = denv * (base2x.freq * 0.9996 - 0.22).tone.complex_sine.at(1).reset(v.trigger)

      eenv = v.fm_env(0, 2, 0.573, 0.5, curve: [-10, 3, 7], sensitivity: -8.9.db..0.db)
      e = eenv * base.complex_sine.at(1).pm(mod * (c + d))

      # FIXME: sounds are too quiet below ~80 velocity
      fenv = v.amp_env(0.001, 2, 0.699, 0.5, curve: [-10, 2, 8], sensitivity: -13.8.db..-3.2.db)
      f = fenv * base.complex_sine.at(1).pm(e * mod)

      f.real * 0.125
    }

    # Reduce aliasing noise
    s = s.softclip(0.8, 0.95).filter(15000.hz.lowpass)
    s = s.oversample(oversample, mode: :libsamplerate_fastest) if oversample > 1

    s + s.delay(100.ms)
  end

  if main_script?(__FILE__)
    synth_script(
      oversample: [4, Integer, 'Oversampling factor (1 for none; less aliasing, more CPU)', 1..8],
    ) { |midi, p| fm_bass(midi, oversample: p.oversample) }
  end
end
