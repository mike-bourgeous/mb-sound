#!/usr/bin/env ruby
# Generates pink noise in a file.  This version uses a window to remove
# possible discontinuities at block boundaries.

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

seconds = ARGV[3].to_f rescue 0
raise "Invalid number of seconds given (must be > 0) #{USAGE}" unless seconds > 0

input = MB::Sound::NullInput.new(channels: 1, length: (48000 * seconds).round)
output = MB::Sound::FFMPEGOutput.new(outfile, rate: 48000, channels: channels)
window = MB::Sound::Window::DoubleHann.new(framesize)

begin
  # TODO write a synthesize_window function so we aren't wasting time
  # generating zeros and windowing them with the input window?
  MB::Sound.process_window(input, output, window) do
    # Multiply by 3.5 (could really get away with 4) to compensate for window
    # averaging loss.  Possibly a more accurate approach would be to look up or
    # calculate the right power spectral density correction factor in Heinzel
    # 2002?
    channels.times.map { MB::Sound::Noise.spectral_pink_noise(bins) * 3.5 }
  end
ensure
  output.close
end
