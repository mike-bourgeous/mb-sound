#!/usr/bin/env ruby
# Generates brown noise in a file.  The output will have a roughly Gaussian
# distribution.

require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

PROGRESS_FORMAT = "\e[36m%a \e[35m%e\e[0m \e[34m[\e[1m%B\e[0;34m] %p%%\e[0m"
RATE = 48000
USAGE = "(usage #{$0} output_filename bins seconds)"

outfile = ARGV[0]
raise "No output filename given #{USAGE}" unless outfile.is_a?(String)

bins = ARGV[1].to_i rescue 0
raise "Invald number of bins given (must be >= 10) #{USAGE}" unless bins >= 10
framesize = (bins - 1) * 2

seconds = ARGV[2].to_f rescue 0
raise "Invalid number of seconds given (must be > 0) #{USAGE}" unless seconds > 0

# FIXME: Need NullInput

input = MB::Sound::NullInput.new(channels: 1, length: (48000 * seconds).round)
output = MB::Sound::FFMPEGOutput.new(outfile, rate: 48000, channels: 1)
window = MB::Sound::Window::DoubleHann.new(framesize)

begin
  MB::Sound.process_window(input, output, window) do
    # Multiply by 3 to compensate for window averaging loss.  Possibly a more
    # accurate approach would be to look up or calculate the right power
    # spectral density correction factor in Heinzel 2002?
    [MB::Sound::Noise.spectral_brown_noise(bins) * 3]
  end
ensure
  output.close
end
