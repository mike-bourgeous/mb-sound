#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# A left/right ping-pong delay
# (C)2025 Mike Bourgeous
#
# Usage: $0 [--delay 0.25] [--feedback 0.8] [--dry 1] [--wet 1] [input_filename [output_filename]]
#
# Plays a sound file (or live input) through the delay, letting the echoes
# ring out after the file ends.  Run with --help for all options.
#
# Examples:
#     # Basic ping-pong delay
#     $0 sounds/transient_synth.flac
#
#     # Weak room slap-back echo simulation
#     $0 --delay 0.01 --feedback 0.3 sounds/drums.flac
#
#     # Acceptable room ambience simulation
#     $0 --wet -1 --delay 0.006 --feedback -0.3 sounds/drums.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  input_channels: 2,
  delay: [0.25, 'Delay in seconds'],
  feedback: [0.8, 'Feedback gain'],
  dry: [1.0, 'Dry (input) level'],
  wet: [1.0, 'Wet (echo) level'],
) { |input, p|
  # TODO: could do more than two channels by multiplying the delay time by the
  # number of channels and then setting up delays to cycle through them all
  l, r = input

  l_delayed = l.delay(p.delay).delay(p.delay * 2, feedback: p.feedback) + l.delay(p.delay)
  r_delayed = r.delay(p.delay * 2, feedback: p.feedback)

  [p.dry * l + p.wet * l_delayed, p.dry * r + p.wet * r_delayed].channels.softclip(0.9)
}
