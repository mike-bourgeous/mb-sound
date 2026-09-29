#!/usr/bin/env ruby
# A simple tape-simulator echo with feedback, one tape per channel.
# (C)2022-2025 Mike Bourgeous
#
# Usage: $0 [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input, stereo unless -c says otherwise) through
# the echo, letting it ring out after the file ends.  Files keep their
# channel count.  Run with --help for all options.
#
# Examples:
#     # synth groove
#     $0 --dry 1.75 --drive 2 --wet 1.5 --delay 0.25 --feedback 1 sounds/transient_synth.flac
#
#     # space ship
#     $0 --dry 0.4 --wet 1.2 --delay 0.25 --feedback 1.06 sounds/sine/log_sweep_20_20k.flac
#
#     # lo-fi crunch
#     $0 --dry 0 --drive 100 --delay 0 --feedback 0 sounds/drums.flac
#
#     # broken time machine
#     $0 --dry 0 --smoothing 0.1 --pitch --delay 0.3333333 --feedback 1.15 sounds/drums.flac
#
#     # arp echoes: a 0.4 s Am7/Amaj7 arp repeating in time, fading over ~7 s
#     $0 --delay 0.4 --feedback 0.7 spec/test_data/arp_a7.flac
#
#     # dub drums
#     $0 --drive 10 --delay 0.166667 --feedback 1.14 sounds/drums.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
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

  delay_samples = MB::M.max((p.delay * sample_rate * p.oversample).round, 0)
  wobble = p.pitch ? 3250 * p.oversample : 0

  # The feedback comes back one internal buffer later, so the buffer must
  # fit inside the shortest delay; larger buffers are much faster (measured
  # in stereo: 32 samples ~180% of realtime, 256 ~45%)
  internal_bufsize = [512, 256, 128, 64, 32].find { |n| n <= delay_samples - wobble } || 32

  delay_samples = delay_samples + -0.4.hz.ramp.forever.at(0..wobble) if p.pitch
  delay_samples = delay_samples.constant if delay_samples.is_a?(Numeric)

  # TODO: ping-pong
  # TODO: MIDI control

  # One tape echo per channel; the feedback loop keeps its own buffer, so it
  # is built separately for each channel rather than per channel by the DSL
  tape_echo = ->(channel) {
    # Read the input in full buffers, so the feedback loop can run with a
    # smaller buffer size.
    inp = channel.with_buffer(800).resample(mode: :libsamplerate_fastest).named('input')

    # Feedback buffer, overwritten by a later call to #spy
    a = Numo::SFloat.zeros(internal_bufsize)

    # Feedback injector and delay.  The feedback comes back one internal
    # buffer late, so the delay line is that much shorter; the input is
    # delayed by the same amount so the first echo isn't early.
    adjusted_delay = (delay_samples.named('delay in samples') - internal_bufsize.constant.named('buffer size')).clip(0, nil)
    tape_in = inp.delay(samples: internal_bufsize, smoothing: false, sample_rate: sample_rate * p.oversample).named('loop latency')
    b = (tape_in * p.drive.constant.named('drive') + 0.constant.proc { a }.named('feedback') * p.feedback)
      .delay(samples: adjusted_delay, smoothing: p.smoothing, sample_rate: sample_rate * p.oversample)
      .named('delay')

    # Tape saturator
    c = b
      .filter(200.hz.highpass(quality: 0.5)).named('highpass')
      .filter(3000.hz.lowpass(quality: 0.5)).named('lowpass')
      .softclip(0, 0.5)
      .named('tape sim')

    # Feedback, with a spy to save feedback buffer, using a shorter buffer
    # size for the feedback loop, allowing shorter delays
    feedback_loop = c.spy { |z| a[] = z if z && z.length == a.length }

    # Final output
    (p.dry.constant.named('dry') * inp + p.wet.constant.named('wet') * feedback_loop)
      .softclip(0.75, 0.95)
      .with_buffer(internal_bufsize)
      .oversample(p.oversample, mode: :libsamplerate_fastest)
      .named('mixed output')
  }

  input.outputs.map(&tape_echo).channels
}
