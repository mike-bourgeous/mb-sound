#!/usr/bin/env ruby
# Generates white noise in a file.  The output will have a roughly Gaussian
# distribution.

require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

PROGRESS_FORMAT = "\e[36m%a \e[35m%e\e[0m \e[34m[\e[1m%B\e[0;34m] %p%%\e[0m"
RATE = 48000
USAGE = "(usage #{$0} output_filename channels bins seconds)"

outfile = ARGV[0]
raise "No output filename given #{USAGE}" unless outfile.is_a?(String)

channels = ARGV[1].to_i rescue 0
raise "Invalid number of channels (must be >= 1) #{USAGE}" unless channels >= 1

bins = ARGV[2].to_i rescue 0
raise "Invald number of bins given (must be >= 10) #{USAGE}" unless bins >= 10
framesize = (bins - 1) * 2
frametime = framesize.to_f / RATE

seconds = ARGV[3].to_f rescue 0
raise "Invalid number of seconds given (must be > 0) #{USAGE}" unless seconds > 0

output = MB::Sound::FFMPEGOutput.new(outfile, sample_rate: 48000, channels: channels)

begin
  loops = (seconds / frametime).ceil
  loops.times do
    # FIXME there's a clear comb filtering effect based on the number of bins
    noise = channels.times.map { MB::Sound::Noise.spectral_white_noise(bins) }
    output.write(MB::Sound.real_ifft(noise, odd_length: false))
  end
ensure
  output.close
end
