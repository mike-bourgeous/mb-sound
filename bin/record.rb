#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Records sound from the default input to a given filename, showing the
# input's meters (peak with hold, RMS, short-term loudness, true peak) beside
# a scope on a band at the bottom of the terminal (the terminal UI's :vis
# layout).  Ctrl-C stops and closes the file.
#
# Usage:
#     $0 output_filename
#
# Example:
#     $0 /tmp/x.flac

require 'bundler/setup'

require 'mb-sound'

MB::Sound.script(args: 1) { |(outfile)|
  input = MB::Sound.input
  output = MB::Sound.file_output(outfile, sample_rate: input.sample_rate, channels: input.channels, overwrite: :prompt)

  pry_next = false
  MB::U.sigquit_backtrace do
    pry_next = true
  end

  MB::U.headline("Recording to #{outfile}")

  # The input's meters on a band (on a terminal; see MB::Sound::UI::BufferFeed)
  feed = MB::Sound::UI::BufferFeed.new(channels: input.channels, sample_rate: input.sample_rate)
  band = MB::Sound::UI::Band.new(layout: MB::Sound::UI.layouts[:vis], source: feed.method(:snapshot)).start if $stdout.tty?

  begin
    loop do
      data = input.read(input.buffer_size)
      feed.push(data)

      if pry_next
        require 'pry-byebug'; binding.pry
        pry_next = false
      end

      output.write(data)
    end
  rescue Interrupt
    puts
  ensure
    band&.stop
    output.close
  end
}
