#!/usr/bin/env ruby
# Experiment to turn any section of a sound into a seamless loop.
#
# Usage:
#     $0 in_filename out_filename loop_start loop_length [crossfade_length]

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help') || ARGV.empty?
  MB::U.print_header_help
  exit 1
end

data = MB::Sound.read(ARGV[0])
outname = ARGV[1]
start = Float(ARGV[2])
length = Float(ARGV[3])
xfade = MB::M.min(ARGV[4]&.to_f || 0.1, length)

rate = 48000
start_samples = start * rate
length_samples = length * rate
xfade_samples = xfade * rate
end_samples = start_samples + length_samples
lead_in_start = MB::M.max(0, start_samples - xfade_samples)
lead_out_end = end_samples + xfade_samples

if data[0].length < start_samples + length_samples + xfade_samples
  # TODO: Allow shortening the lead-out somewhat?
  raise "Sound is too short (must be #{start + length + xfade}s; got #{data[0].length / rate.to_f}s)"
end

# In-place fades the fade_in and fade_out clips.
def fade(clip, fade_in)
  # TODO: use a decibel fade?
  fade = Numo::SFloat.linspace(fade_in ? 0 : 1, fade_in ? 1 : 0, clip.length).map { |v| MB::M.smootherstep(v) }
  clip.inplace * fade
end

looped = data.map { |c|
  c.not_inplace!

  # Lead-in is taken from before the loop and mixed in at the end of the loop
  if start_samples > 0
    lead_in = c[lead_in_start...start_samples]
    lead_in = fade(lead_in, true)
  else
    lead_in = Numo::SFloat[0]
  end

  middle = c[start_samples...end_samples].dup

  # Lead-out is taken from after the loop and mixed in at the start of the loop
  lead_out = c[end_samples...lead_out_end]
  lead_out = fade(lead_out, false)

  middle[0...lead_out.length].inplace + lead_out
  middle[-lead_in.length...].inplace + lead_in

  # XXX for testing - lead_in.concatenate(middle).concatenate(lead_out)
  middle
}

MB::U.headline("Writing #{looped[0].length / rate.to_f}s of audio to #{outname}")

MB::Sound.write(outname, looped)
