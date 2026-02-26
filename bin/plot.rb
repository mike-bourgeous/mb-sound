#!/usr/bin/env ruby
# Plots a given audio file.
# Usage: $0 filename

require 'bundler/setup'

require 'mb/util'

require 'mb/sound'

graphical = !!ARGV.delete('--graphical')

if ARGV.length != 1 || ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

data = MB::Sound.read(ARGV[0])
loop do
  # TODO: there's got to be a better way to respond to window size changes
  MB::Sound.plot(data, samples: data[0].length, graphical: graphical)
  break unless graphical
  sleep
end
