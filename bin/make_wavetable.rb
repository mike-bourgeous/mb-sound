#!/usr/bin/env ruby
# Chops any sound file into a wavetable.
#
# Works by trying to detect the fundamental frequency of the sound, then
# slicing and blending the sound into loopable chunks of the fundamental
# period.
#
# Usage:
#     $0 [options] in_filename out_filename

require 'bundler/setup'
require 'mb-sound'

MB::Sound.script(
  args: 2,
  blur: [0.0, '-b', 'Weighting factor for blurring adjacent waves', -1.0..1.0],
  quiet: [false, '-q', 'Disable plotting the wavetable'],
  size: [10, '-s', 'The number of waves to add to the table', 1..],
  ratio: [1.0, '-r', 'Multiply the detected wave period by this ratio'],
  force: [false, '-f', 'Overwrite an existing file (default: prompt)'],
) { |(inname, outname), p|
  table_size = p.size
  ratio = p.ratio

  # TODO: Support stereo wavetable generation?
  data = MB::Sound.read(inname)
  if data.length == 2
    # Blend channels with some phase rotation so side info isn't completely canceled
    # FIXME: This introduces some very loud high frequency oscillation so just using L for now
    #mid = data.sum
    #side = (MB::Sound.analytic_signal(data[0] - data[1]) * 1i).real
    #data = mid + side
    data = data[0]
  else
    data = data.sum / data.length
  end
  data.not_inplace!

  MB::U.headline("Estimating frequency of #{inname}", color: '1;34')

  metadata = {}
  result = MB::Sound::Wavetable.make_wavetable(data, slices: table_size, ratio: ratio, metadata_out: metadata)

  if p.blur != 0
    10.times do
      result = MB::Sound::Wavetable.blur(result, p.blur / 10.0)
    end
  end
  result = MB::Sound::Wavetable.normalize(result)

  MB::Sound.plot(result) unless p.quiet

  MB::U.headline("Writing to #{outname}")
  MB::U.table(metadata.merge(p.to_h).to_a)
  MB::Sound::Wavetable.save_wavetable(outname, result, overwrite: p.force ? true : :prompt)

  MB::U.headline "Code to load this wavetable in bin/sound.rb:", color: 36
  puts "\n#{MB::U.syntax("data = MB::Sound::Wavetable.load_wavetable(#{outname.inspect})")}"
  puts "#{MB::U.syntax("plot data, graphical: true")}"
  puts "or\n#{MB::U.syntax("play midi.env * midi.hz.ramp.wavetable(#{outname.inspect})")}\n\n"
}
