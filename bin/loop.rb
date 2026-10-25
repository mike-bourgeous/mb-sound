#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Loops an audio file until interrupted.
#
# Usage: $0 sound_filename

require 'bundler/setup'
require 'mb-sound'

MB::U.sigquit_backtrace

MB::Sound.script(args: 1) { |(file)|
  MB::Sound.play MB::Sound::Sample[file].looped
}
