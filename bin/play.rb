#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plays audio files (and tracker modules: .mod, .669, .s3m, .xm, .it), one
# after another, while showing meters.
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
