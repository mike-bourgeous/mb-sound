#!/usr/bin/env ruby
# Interactive sound environment.  Uses Pry within the MB::Sound module context.
# See README.md for more info, including copyright and license.

require 'rubygems'
require 'bundler/setup'

require 'benchmark'

require 'io/console'

Bundler.require

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

def clear
  STDOUT.write("\e[H\e[2J")
  STDOUT.flush
end

puts
clear if ARGV.include?('--clear')

def show_intro
  puts MB::Sound::U.wrap(<<-EOF.strip)
\e[33;1mWelcome to the interactive sound environment!\e[0m

If you're new to Ruby, see https://www.ruby-lang.org/en/documentation/quickstart/.
If you're new to Pry, check out https://pry.github.io/.

\e[3mSome things to try:\e[0m

\e[1mls\e[0m (for "list") to get a list of the easiest to use sound functions.

\e[1;32m#{MB::Sound::U.syntax("list")}\e[0m to get a list of included sounds.

\e[1;33m#{MB::Sound::U.syntax("play 'sounds/sine/sine_100_1s_mono.flac'")}\e[0m to play a sound file.

\e[1;33m#{MB::Sound::U.syntax("play 123.hz")}\e[0m to play a 123Hz tone for a few seconds.

\e[1;33m#{MB::Sound::U.syntax("play 123.hz.triangle.at(-20.db).forever")}\e[0m to play a 123Hz triangle wave tone forever.

\e[1;35m#{MB::Sound::U.syntax("plot 123.hz")}\e[0m to graph part of a 123Hz tone.

\e[1;35m#{MB::Sound::U.syntax("plot 123.hz, all: true")}\e[0m to graph a 123Hz tone as it would be played.

\e[1;35m#{MB::Sound::U.syntax("plot 'sounds/sine/sine_100_1s_mono.flac', all: true")}\e[0m to graph a sound file at the same speed it would be played.

\e[1;33m#{MB::Sound::U.syntax("123.hz.wavelength")}\e[0m to show the wavelength of a 123Hz tone (at room temperature at sea level).

\e[1m#{MB::Sound::U.syntax('cd ::')}\e[0m for experienced Ruby/Pry users to leave the sound context.
  EOF
end

show_intro

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
