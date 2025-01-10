#!/usr/bin/env ruby
# Prints information about a media file.
#
# Usage: $0 filename

require 'bundler/setup'

require 'mb/util'

require 'mb/sound'

if ARGV.length != 1 || ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

puts MB::U.highlight(MB::Sound::FFMPEGInput.parse_info(ARGV[0]))
