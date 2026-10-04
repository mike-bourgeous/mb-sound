#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plays audio files, one after another, while showing meters.
#
# Usage: $0 sound_filename [...]

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

MB::Sound.script(args: 1..) { |files|
  # TODO: gapless playback
  files.each do |f|
    MB::Sound.play f
  end
}
