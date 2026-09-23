#!/usr/bin/env ruby
# A left/right ping-pong delay
# (C)2025 Mike Bourgeous
#
# Usage: [DRY=] [WET=] $0 [delay_s [feedback [extra_time]]] [input_filename]
#
# Examples:
#     # Basic ping-pong delay
#     $0 sounds/transient_synth.flac
#
#     # Weak room slap-back echo simulation
#     $0 sounds/drums.flac 0.01 0.3
#
#     # Acceptable room ambience simulation
#     WET=-1 $0 0.006 -0.3 sounds/drums.flac

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A[+-]?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback, extra, *_ = numerics.map(&:to_f)
delay ||= 0.25
feedback ||= 0.8
extra ||= 2

filename, *_ = others

if filename && File.readable?(filename)
  input = MB::Sound.file_input(filename, channels: 2)
else
  input = MB::Sound.input(channels: 2).named('Audio input')
end

# TODO: support writing to an output file
# TODO: really could use an abstraction around standalone effects for file/live i/o

output = MB::Sound.output(channels: input.channels)

internal_bufsize = 100

dry = ENV['DRY']&.to_f || 1
wet = ENV['WET']&.to_f || 1

puts MB::U.highlight({
  dry: dry,
  wet: wet,
  delay: delay,
  feedback: feedback,
  extra: extra,
})

# TODO: could do more than two channels by multiplying the delay time by the
# number of channels and then setting up delays to cycle through them all

# TODO: have a ringdown graph node that continues running until its input becomes close enough to silent
ringdown = 0.constant.for(extra + delay * (2 + 20 * feedback.abs))
in_l, in_r = input.split.map { |c| c.and_then(ringdown.get_sampler) }

l_delayed = in_l.delay(seconds: delay).delay(seconds: delay * 2, feedback: feedback) + in_l.delay(seconds: delay)
r_delayed = in_r.delay(seconds: delay * 2, feedback: feedback)

out_l = dry * in_l + wet * l_delayed
out_r = dry * in_r + wet * r_delayed

MB::Sound.play([out_l.softclip(0.9), out_r.softclip(0.9)], output: output)
