#!/usr/bin/env ruby
# Very simple granular delay repeater.
# (C)2024 Mike Bourgeous
#
# Usage: $0 [--help] [--delay=seconds] [--count=integer]

require 'bundler/setup'

require 'getoptlong'

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
# - Grain size / delay size
# - Number of repeats
# - Stereo spread?

opts = GetoptLong.new(
  [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
  [ '--delay', '-d', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--count', '-c', GetoptLong::REQUIRED_ARGUMENT ],
)

delay = 0.125
count = 2
opts.each do |opt, arg|
  case opt
  when '--help'
    MB::U.print_header_comment
    exit 1

  when '--delay'
    delay = arg.to_f
    raise 'delay must be positive' unless delay > 0

  when '--count'
    count = arg.to_i
    raise NotImplementedError, 'Only a count of 2 is supported at this time' unless count == 2
  end
end

puts MB::U.highlight({count: count, delay: delay})
puts "\e[1;31mTODO\e[0m"
exit 1
