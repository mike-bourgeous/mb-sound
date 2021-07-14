#!/usr/bin/env ruby
# Plays an audio file while showing meters.

require 'bundler/setup'
require 'pry-byebug'
require 'mb-sound'

MB::Sound.play ARGV[0]
