#!/usr/bin/env ruby
# Generates pink noise in a file.  This version uses a window to remove
# possible discontinuities at block boundaries.

#
# Usage: $0 [options] output_filename
#
# Example:
#     $0 --channels 2 --seconds 30 /tmp/pink.flac

require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

PROGRESS_FORMAT = "\e[36m%a \e[35m%e\e[0m \e[34m[\e[1m%B\e[0;34m] %p%%\e[0m"
RATE = 48000

MB::Sound.script(
  args: 1,
  channels: [1, '-c', 'Number of channels', 1..],
  bins: [2401, '-b', 'Spectrum bins per block', 10..],
  seconds: [10.0, '-s', 'Length in seconds', 0.001..],
  force: [false, '-f', 'Overwrite the output file'],
) { |(outfile), p|
  channels = p.channels
  bins = p.bins
  seconds = p.seconds
  framesize = (bins - 1) * 2

  output = MB::Sound.file_output(outfile, sample_rate: 48000, channels: channels, overwrite: p.force || :prompt)
  window = MB::Sound::Window::DoubleHann.new(framesize)

  begin
    length = 0
    # TODO: Get the length exactly right (it gets padded with window lead-in and drain-out)
    MB::Sound.synthesize_window(output, window) do
      break if length >= seconds
      length += window.hop / 48000.0

      # Multiply by 3.5 (could really get away with 4) to compensate for window
      # averaging loss.  Possibly a more accurate approach would be to look up or
      # calculate the right power spectral density correction factor in Heinzel 2002?
      channels.times.map { MB::Sound::Noise.spectral_pink_noise(bins) * 3.5 }
    end
  ensure
    output.close
  end
}
