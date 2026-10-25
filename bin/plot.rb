#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plots a given audio file.
#
# Usage: $0 [--graphical] filename

require 'bundler/setup'

require 'mb/util'

require 'mb/sound'

MB::Sound.script(
  args: 1,
  graphical: [false, 'Plot as an inline terminal image (iTerm2, kitty, sixel)'],
) { |(filename), p|
  data = MB::Sound.read(filename)

  MB::Sound.plot(data, samples: data[0].length, graphical: p.graphical)
}
