#!/usr/bin/env ruby
# Records sound from the default input to a given filename.
#
# Usage:
#     $0 output_filename
#
# Example:
#     $0 /tmp/x.flac

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

outfile = ARGV[0]
raise "No filename given" unless outfile

input = MB::Sound.input
output = MB::Sound::PlotOutput.new(MB::Sound.file_output(outfile, sample_rate: input.sample_rate, channels: input.channels))

pry_next = false
MB::U.sigquit_backtrace do
  pry_next = true
end

MB::U.headline("Recording to #{outfile}")

begin
  loop do
    data = input.read(input.buffer_size)

    if pry_next
      require 'pry-byebug'; binding.pry
      pry_next = false
    end

    output.write(data)
  end
ensure
  output.close
end
