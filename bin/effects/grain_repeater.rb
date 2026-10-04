#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Very simple granular delay repeater.
# (C)2024 Mike Bourgeous
#
# Usage: $0 [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input, stereo unless -c says otherwise) through
# the repeater.  Run with --help for all options.
#
# Examples:
#     $0 --delay=0.02083333 --count=8 sounds/drums.flac
#     $0 --delay=0.05 --count=8 sounds/synth0.flac
#     $0 --delay=0.5 --count=2 sounds/sine/log_sweep_20_20k.flac

require 'bundler/setup'

require 'mb-sound'

# The idea is to have every other N samples play live, followed by the same N
# samples delayed.
#
# Some possible ways to go about this:
# 1. Use an ordinary delay line and a square wave or stepped oscillator to
#    control the delay time.
# 2. Build a granular-specific delay buffer that can be told to start playing a
#    grain at a specific point in past absolute time, or something like that.
# 3. Use a fixed-time delay and modulate the amplitude of the wet and dry
#    signals using a square wave.
#
# Ideas for improvement:
# - MIDI CC control (of course)
# - Trigger on MIDI CC (possibly with a "forever" mode; this would require
#   using something other than a classical delay line)
# - Retrigger based on MIDI note (just reset the phase of the delay time oscillator)
# - Retrigger based on audio envelope
# - Delay time based pitch on MIDI note
# - Repeat while MIDI note is held
# - Normalize/semi-normalize/compress volume of each grain, maybe with noise
#   gate or expander
# - Multiple different delays and repeats in parallel or series

# Parameters:
# - Grain size / delay size
# - Number of repeats
# - Stereo spread?

MB::Sound.effect_script(
  delay: [0.125, '-d', 'Grain length in seconds', 0.001..],
  count: [2, '-n', 'Times each grain plays', 2..],
) { |input, p|
  period = p.count * p.delay
  rate = 1.0 / period

  input.outputs.map { |inp|
    # TODO: cross-fade two delays with opposite phase instead of fading out and back in?
    # TODO: use a constant number of samples with smoothstep for the fade instead of scaling a sine wave
    fade_osc = (1.0 / p.delay).hz.sine.at(0..500).with_phase(-Math::PI / 2).aclip(0, 1)

    delay_osc = rate.hz.with_phase(Math::PI).ramp.at(0..1.0).proc { |v| (v * p.count).floor / (p.count - 1.0) } * (period - p.delay)

    # FIXME: if max_delay isn't set, then the first time the delay equals one second the buffer is lost
    # e.g. bin/effects/grain_repeater.rb --delay=0.5 -c 3 --count=3 sounds/drums.flac result.flac
    inp.delay(seconds: delay_osc, smoothing: false, max_delay: period) * fade_osc
  }.channels
}
