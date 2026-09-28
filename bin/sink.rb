#!/usr/bin/env ruby
# Ignores input to keep Pipewire from closing a USB audio interface.
#
# Usage: $0

require 'bundler/setup'
require 'mb-sound'

MB::Sound.script(args: 0) {
  input = MB::Sound.input(channels: 1)

  loop do
    input.read(input.buffer_size)
  end
}
