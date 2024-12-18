#!/usr/bin/env ruby
# Very simple granular delay repeater.
# (C)2024 Mike Bourgeous

require 'bundler/setup'

require 'mb/sound'

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

# Parameters:
# - Grain size
# - Number of repeats
# - Stereo spread?


