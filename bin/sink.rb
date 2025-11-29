#!/usr/bin/env ruby
# Ignores input to keep Pipewire from closing a USB audio interface.

require 'bundler/setup'

require 'mb-sound'

input = MB::Sound.input(channels: 1)

loop do
  input.read(input.buffer_size)
end
