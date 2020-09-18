#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'benchmark'

require 'io/console'

Bundler.require

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

puts
puts `clear` if ARGV.include?('--clear')

puts MB::Sound::U.wrap(<<-EOF.strip)
\e[33;1mWelcome to the interactive sound environment!\e[0m

If you're new to Ruby, see https://www.ruby-lang.org/en/documentation/quickstart/.
If you're new to Pry, check out https://pry.github.io/.

\e[3mSome things to try:\e[0m

\e[1mls\e[0m (for "list") to get a list of the easiest to use sound functions.

\e[1m#{MB::Sound::U.syntax("Dir['sounds/**/*.*']")}\e[0m to get a list of included sounds.

\e[1m#{MB::Sound::U.syntax("play('sounds/sine/sine_100_1s_mono.flac')")}\e[0m to play a sound file.

\e[1m#{MB::Sound::U.syntax('cd ::')}\e[0m for experienced Ruby/Pry users to leave the sound context.

EOF

Pry.config.commands.rename_command('pry-play', 'play')

Pry.pry(
  MB::Sound,
  prompt: Pry::Prompt.new(:mb_sound, "The interactive sound environment's default prompt", [
    _pry_a = -> (obj, nest, pry) {
      "\1\e[36m\2#{File.basename($0)}\1\e[0m\2 \1\e[32m\2#{obj}\1\e[0;2m\2(#{nest}) > \1\e[0m\2"
    },
    -> (obj, nest, pry) {
      ' ' * _pry_a.call(obj, nest, pry).gsub(/(\x01|\x02|\e\[[0-9;]*[A-Za-z])/, '').length
    }
  ])
)
