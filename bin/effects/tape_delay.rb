#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
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
  # The echo is a feedback loop (GraphNode#feedback through #delay's block)
  # that runs one sample at a time, so any delay works (down to one
  # sample) and the repeats are exactly --delay apart: the delay absorbs
  # the tape sim's own latency.  (Until 2026-10-09 this script ran the loop
  # in internal blocks of 32-512 samples with a spy, shortening the delay
  # by a block; the sound is the same apart from the tape filters' few
  # samples of latency, now compensated.)
  #
  # The delay time in seconds, wobbling for --pitch
  time = p.pitch ? p.delay + -0.4.hz.ramp.at(0..(3250 / 48000.0)) : p.delay

  # One tape echo per channel
  tape_echo = ->(channel) {
    # Resampled so --oversample runs the whole echo at the higher rate
    inp = channel.resample(mode: :libsamplerate_fastest).named('input')

    # The tape loop: drive into the delay, the feedback through the tape
    # sim (band limits and saturation) on every pass, including the first
    # echo (as the old spy loop did)
    echo = (inp * p.drive.constant.named('drive')).delay(time, feedback: p.feedback, smoothing: p.smoothing) { |fb|
      fb
        .filter(200.hz.highpass(quality: 0.5)).named('highpass')
        .filter(3000.hz.lowpass(quality: 0.5)).named('lowpass')
        .softclip(0, 0.5)
        .named('tape sim')
    }.named('tape loop')

    # Final output
    (p.dry.constant.named('dry') * inp + p.wet.constant.named('wet') * echo)
      .softclip(0.75, 0.95)
      .oversample(p.oversample, mode: :libsamplerate_fastest)
      .named('mixed output')
  }

  input.outputs.map(&tape_echo).channels
}
