#!/usr/bin/env ruby
# Plays silence forever to try to keep the USB audio interface open.

require 'bundler/setup'

require 'mb-sound'

output = MB::Sound.output(channels: 1)
data = Numo::SFloat.zeros(output.buffer_size)

loop do
  output.write([data])
end
