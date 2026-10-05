#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Episode 2 of Code Sound & Surround, rebuilt on today's synth API
# Synthesizahh!!!
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Plays live MIDI, or a MIDI file, through sawtooth voices into one resonant
# lowpass filter; CC 1 (the mod wheel) sweeps the filter from 20 Hz to 20
# kHz.  The output is stereo; --impulse puts the filter's impulse response
# on the second channel instead, for scopes (it never goes quiet, so MIDI
# files play on for the 10 s tail limit).  Run with --help for all options.
# The episode's original script is in the repository's history.
#
# A tour of the synth API (see MB::Sound::Synth and MB::Sound::Notes):
# - midi.synth(voices:) { |v| ... } builds one voice per lane; `v` is that
#   voice's notes as signals (v.hz, v.gate, v.velocity, v.amp_env, ...).
# - v.hz.saw restarts its phase at each note (key sync; .free to let it run).
# - v.amp_env shapes the level, with velocity from -18 dB to 0 dB.
# - v.hz.glide(:gm) glides when CC 65 (portamento) is on, over CC 5's time.
# - midi.cc(1, ...) is a controller as a signal, shared by every voice.
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid         # a MIDI file
#     $0 spec/test_data/mod_wheel.mid ep2.flac
#     $0 --impulse                          # impulse response on the right
#     $0 --voices 1                         # mono (the newest held note plays)

require 'bundler/setup'
require 'mb-sound'

MB::Sound.tuning b4: 480

MB::Sound.synth_script(
  voices: [8, Integer, 'Number of voices (1 for mono)', 1..32],
  impulse: [false, "Play the filter's impulse response on the second channel instead of the synth"],
) { |midi, p|
  synth = midi.synth(voices: p.voices) { |v|
    v.hz.glide(:gm).saw * v.amp_env(0.005, 0.2, 0.8, 0.1)
  }

  # The mod wheel sweeps the cutoff over three decades, 20 * 10 ** (0..3)
  # Hz, starting at 20 * 10 ** 1.8 (about 1260 Hz)
  decades = midi.cc(1, range: 0.0..3.0, default: 76, name: 'Cutoff decades')
  cutoff = (20 * 10 ** decades).named('Cutoff')

  filter = 1500.hz.lowpass(quality: 4)
  out = (synth.oversample(16, mode: :libsamplerate_fastest).filter(filter, cutoff: cutoff) * 0.2).softclip(0.5)
  next out.stereo unless p.impulse

  # Built from the synth's output so it ends when the synth does
  impulse = out.proc { |d| filter.impulse_response(d.length) }.named('Impulse')
  [out, impulse].channels
}
