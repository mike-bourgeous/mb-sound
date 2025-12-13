#!/usr/bin/env ruby
# Experiment to chop a sound into a wavetable.
#
# Usage:
#     $0 in_filename out_filename [[table_size] ratio] [--quiet]
#
#     table_size defaults to 100
#     ratio is a multiple of the fundamental period for each wave; defaults to 1
#       ideally should be integer multiples

require 'bundler/setup'

require 'mb-sound'

if ARGV.include?('--help') || ARGV.empty?
  MB::U.print_header_help
  exit 1
end

quiet = !!ARGV.delete('--quiet')

inname = ARGV[0]
raise 'No input file given' unless inname

outname = ARGV[1]
raise 'No output file given' unless outname

table_size = Integer(ARGV[2] || 100)
ratio = Float(ARGV[3] || 1)

# TODO: Support stereo wavetable generation?
data = MB::Sound.read(ARGV[0])
if data.length == 2
  data = (data[0] + 1i * data[1]).real
else
  data = data.sum
end

MB::U.headline("Estimating frequency of #{inname}", color: '1;34')

freq = MB::Sound.freq_estimate(data, range: 30..120)
period = ratio.to_f / freq
xfade = period * 0.25

rate = 48000
length_samples = (period * rate).round
xfade_samples = (xfade * rate).round

jump = (data.length - length_samples - xfade_samples) / (table_size - 1)

note_name = MB::Sound::Tone.new(frequency: freq).to_note.name

# TODO: Add all metadata to the file including root note, etc.
MB::U.headline("Writing to #{outname}")
outfile = MB::Sound.file_output(outname, overwrite: :prompt, channels: 1, metadata: { mb_sound_wavetable_period: length_samples })

# TODO: maybe chop off leading and trailing silence/near-silence
# TODO: guard against amplifying very high frequency noises e.g. 20k+ dithering noise?

# In-place fades the fade_in and fade_out clips.
def fade(clip, fade_in)
  # TODO: use a decibel fade?
  # TODO: use smoothstep_buf from FastSound?
  fade = Numo::SFloat.linspace(fade_in ? 0 : 1, fade_in ? 1 : 0, clip.length).map { |v| MB::M.smootherstep(v) }
  clip.inplace * fade
end

total = 0

begin
  data.not_inplace!

  puts "\e[H\e[2J" unless quiet

  for start_samples in (0...(data.length - (length_samples + xfade_samples))).step(jump) do
    start_samples = start_samples.floor
    end_samples = start_samples + length_samples
    lead_in_start = MB::M.max(0, start_samples - xfade_samples)
    lead_out_end = end_samples + xfade_samples

    if data.length < start_samples + length_samples + xfade_samples
      # TODO: Allow shortening the lead-out somewhat?
      raise "Sound is too short (must be #{start_samples + length_samples + xfade_samples} samples; got #{data.length} samples)"
    end

    # Take lead-in from before the loop (mixed in at the end of the loop)
    if start_samples > 0
      lead_in = data[lead_in_start...start_samples].dup
      lead_in = fade(lead_in, true)
    else
      lead_in = Numo::SFloat[0]
    end

    # Copy loopable segment
    middle = data[start_samples...end_samples].dup

    # Take lead-out from after the loop (mixed in at the start of the loop)
    lead_out = data[end_samples...lead_out_end].dup
    lead_out = fade(lead_out, false)

    # Add lead-in and lead-out to segment
    middle[0...lead_out.length].inplace + lead_out
    middle[-lead_in.length...].inplace + lead_in

    # Normalize and remove DC offset
    middle -= (middle.sum / middle.length)
    max = MB::M.max(middle.abs.max, -60.db)
    middle = (middle / max) * -2.db

    # Rotate phase to put positive zero crossing at beginning/end
    zc_index = MB::M.find_zero_crossing(middle)
    looped = MB::M.rol(middle, zc_index) if zc_index

    # Quick-fade edges in case the zero crossing wasn't exactly zero
    # TODO: do this?
    #fade(looped[0...30].inplace, true)
    #fade(looped[-30..-1].inplace, false)

    unless quiet
      puts "\e[H"
      MB::Sound.plot(looped, samples: looped.length)
      sleep 0.01
    end

    total += looped.length

    outfile.write(looped)
  end

ensure
  outfile.close
end

MB::U.table(
  {
    Root: note_name,
    Frequency: freq,
    Period: period,
    Ratio: ratio,
    Samples: length_samples,
    Jump: jump,
  },
  variable_width: true
)

MB::U.headline "Code to load this wavetable in bin/sound.rb:", color: 36
puts "\n#{MB::U.syntax("data = MB::Sound.read(#{outname.inspect})[0].reshape(#{total / length_samples}, #{length_samples})")}"
puts "or\n#{MB::U.syntax("data = MB::Sound::Wavetable.load_wavetable(#{outname.inspect})")}"
puts "#{MB::U.syntax("plot data, graphical: true")}\n\n"
