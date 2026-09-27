#!/usr/bin/env ruby
# A simple, mono, tape-simulator echo with feedback.
# (C)2022-2025 Mike Bourgeous
#
# Usage: $0 [delay_s [feedback]] [input_filename [output_filename]] [--dry 1.0] [--wet 1.0] [--drive 1.0] [--pitch [--smoothing 2]]
#
# Plays a sound file (or live input) through the echo, letting it ring out
# after the file ends.  Stereo files are mixed down to mono.  Run with --help
# for all options.
#
# Examples:
#     # synth groove
#     $0 --dry 1.75 --drive 2 --wet 1.5 0.25 1 sounds/transient_synth.flac
#
#     # space ship
#     $0 --dry 0.4 --wet 1.2 0.25 1.06 sounds/sine/log_sweep_20_20k.flac
#
#     # lo-fi crunch
#     $0 --dry 0 --drive 100 0 0 sounds/drums.flac
#
#     # broken time machine
#     $0 --dry 0 --smoothing 0.1 --pitch 0.3333333 1.15 sounds/drums.flac
#
#     # dub drums
#     $0 --drive 10 0.166667 1.14 sounds/drums.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  input_channels: 1,
  delay: [0.1, 'Delay in seconds'],
  feedback: [0.75, 'Feedback gain'], # TODO: Allow controlling first delay amplitude separately
  dry: [1.0, 'Dry (input) level'],
  wet: [1.0, 'Wet (echo) level'],
  drive: [1.0, 'Input gain into the tape'],
  smoothing: [2.0, 'Delay time smoothing rate'],
  pitch: [false, 'Wobble the delay time for pitch effects'],
  oversample: [2.0, 'Oversampling factor'],
) { |input, p|
  sample_rate = 48000
  internal_bufsize = 32

  delay_samples = MB::M.max((p.delay * sample_rate * p.oversample).round, 0)
  delay_samples = delay_samples + -0.4.hz.ramp.forever.at(0..(3250 * p.oversample)) if p.pitch

  # TODO: stereo+, ping-pong
  # TODO: MIDI control

  # Read the input in full buffers, so the feedback loop can run with a
  # smaller buffer size.
  # TODO: maybe this should be automatic
  inp = input.mono.with_buffer(800).resample(mode: :libsamplerate_fastest).named('input')

  # Feedback buffer, overwritten by a later call to #spy
  a = Numo::SFloat.zeros(internal_bufsize)

  # Feedback injector and delay
  adjusted_delay = (delay_samples.constant.named('delay in samples') - internal_bufsize.constant.named('buffer size')).clip(0, nil)
  b = (inp * p.drive.constant.named('drive') + 0.constant.proc { a }.named('feedback') * p.feedback)
    .delay(samples: adjusted_delay, smoothing: p.smoothing, sample_rate: sample_rate * p.oversample)
    .named('delay')

  # Tape saturator
  c = b
    .filter(200.hz.highpass(quality: 0.5)).named('highpass')
    .filter(3000.hz.lowpass(quality: 0.5)).named('lowpass')
    .softclip(0, 0.5)
    .named('tape sim')

  # Feedback, with a spy to save feedback buffer, using a shorter buffer size
  # for the feedback loop, allowing shorter delays
  feedback_loop = c.spy { |z| a[] = z if z && z.length == a.length }

  # Final output
  (p.dry.constant.named('dry') * inp + p.wet.constant.named('wet') * feedback_loop)
    .softclip(0.75, 0.95)
    .with_buffer(internal_bufsize)
    .oversample(p.oversample, mode: :libsamplerate_fastest)
    .named('mixed output')
}
