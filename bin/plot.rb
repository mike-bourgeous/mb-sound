#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Plots a given audio file.
#
# Usage: $0 [--graphical] filename

require 'bundler/setup'

require 'mb/util'

require 'mb/sound'

MB::Sound.script(
  args: 1,
  graphical: [false, 'Plot in a graphical window (and keep redrawing it)'],
) { |(filename), p|
  data = MB::Sound.read(filename)

  loop do
    # TODO: there's got to be a better way to respond to window size changes
    MB::Sound.plot(data, samples: data[0].length, graphical: p.graphical)
    break unless p.graphical
    sleep
  end
}
