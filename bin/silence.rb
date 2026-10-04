#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plays silence forever to try to keep the USB audio interface open.
#
# Usage: $0

require 'bundler/setup'
require 'mb-sound'

MB::Sound.script(args: 0) {
  output = MB::Sound.output(channels: 1)
  data = Numo::SFloat.zeros(output.buffer_size)

  loop do
    output.write([data])
  end
}
