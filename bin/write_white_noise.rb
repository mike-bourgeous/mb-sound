#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Generates white noise in a file.  The output will have a roughly Gaussian
# distribution.

#
# Usage: $0 [options] output_filename
#
# Example:
#     $0 --channels 2 --seconds 30 /tmp/white.flac

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
  frametime = framesize.to_f / RATE

  output = MB::Sound.file_output(outfile, sample_rate: 48000, channels: channels, overwrite: p.force || :prompt)

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
}
