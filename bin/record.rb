#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Records sound from the default input to a given filename.
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

  begin
    loop do
      data = input.read(input.buffer_size)

      MB::Sound::Meter.linear_meters(data.map { |d| d.abs.max })

      if pry_next
        require 'pry-byebug'; binding.pry
        pry_next = false
      end

      output.write(data)
    end
  ensure
    output.close
  end
}
