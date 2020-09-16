#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'benchmark'

require 'io/console'

Bundler.require

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb/sound'

puts WordWrap.ww(<<-EOF, IO.console.winsize[1], true)

\e[33;1mWelcome to the interactive sound environment!\e[0m

If you're new to Pry, check out https://pry.github.io/.

\e[3mSome things to try:\e[0m

\e[1mls \e[32mMB::Sound\e[0m (that's \e[1mls\e[0m for "list") to get a list of the easiest to
use sound functions.

EOF

Pry.pry(
  prompt: Pry::Prompt.new(:mb_sound, "The interactive sound environment's default prompt", [
    _pry_a = -> (obj, nest, pry) {
      "\1\e[36m\2#{File.basename($0)}\1\e[0m\2 \1\e[32m\2#{obj}\1\e[0;2m\2(#{nest}) > \1\e[0m\2"
    },
    -> (obj, nest, pry) {
      ' ' * _pry_a.call(obj, nest, pry).gsub(/(\x01|\x02|\e\[[0-9;]*[A-Za-z])/, '').length
    }
  ])
)
