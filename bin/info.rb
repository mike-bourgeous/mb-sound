#!/usr/bin/env ruby
# Prints information about a media file.
#
# Usage: $0 filename

require 'bundler/setup'

require 'mb/util'

require 'mb/sound'

MB::Sound.script(args: 1) { |(filename)|
  puts MB::U.highlight(MB::Sound::FFMPEGInput.parse_info(filename))
}
