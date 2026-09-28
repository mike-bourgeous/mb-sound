#!/usr/bin/env ruby
# Loops an audio file until interrupted.
#
# Usage: $0 sound_filename

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

MB::Sound.script(args: 1) { |(file)|
  data = MB::Sound.read(file)
  inp = MB::Sound::ArrayInput.new(data: data, repeat: true)
  MB::Sound.play inp
}
