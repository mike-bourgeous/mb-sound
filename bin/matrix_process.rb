#!/usr/bin/env ruby
# Multiplies each sample of an audio file by a processing matrix to produce a
# new output file.
#
# The number of channels in the input file *should* match the number of columns
# in the processing matrix.  If not, then FFMPEG will try to upmix or downmix
# the number of channels to match.
#
# The number of rows in the matrix will determine the number of channels in the
# output file.
#
# The matrix file should be a CSV, TSV, JSON, or YAML file that contains a 1D
# or 2D array of numbers (real or complex).  See
# MB::Sound::MatrixProcess.from_file for more information about the matrix file
# format.

require 'bundler/setup'
require 'mb/sound'

USAGE = <<-EOF.strip
\e[0;1mUsage:\e[0m #{$0} input_audio matrix_file output_audio

\e[0;36m#{MB::U.read_header_comment.join.strip}
\e[0m
EOF

if ARGV.include?('--help')
  puts USAGE
  exit 1
end

raise USAGE unless ARGV.length == 3
in_file, mat_file, out_file = ARGV

raise "Input file #{in_file.inspect} not found.\n#{USAGE}" unless File.readable?(in_file)
raise "Matrix file #{mat_file.inspect} not found.\n#{USAGE}" unless File.readable?(mat_file)

p = MB::Sound::MatrixProcess.from_file(mat_file)

puts "\nProcessing \e[1;34m#{in_file.inspect}\e[0m through matrix \e[1;36m#{mat_file.inspect}\e[0m."
puts "Expecting \e[1m#{p.input_channels}\e[0m input channel(s), producing \e[1m#{p.output_channels}\e[0m output channel(s)."

MB::U.prevent_overwrite(out_file, prompt: true)

input_stream = MB::Sound::FFMPEGInput.new(in_file, channels: p.input_channels)
input = input_stream.read(input_stream.frames)
input_stream.close

if input_stream.info[:channels] != p.input_channels
  puts "\e[1mNote:\e[0;33m audio file originally had \e[1m#{input_stream.info[:channels]}\e[22m channel(s), not \e[1m#{p.input_channels}\e[0m."
end

# TODO: Somehow pass channel layout to FFMPEG
output_stream = MB::Sound::FFMPEGOutput.new(out_file, rate: input_stream.rate, channels: p.output_channels)
output = p.process(input)
output_stream.write(output)
output_stream.close

puts "\n\e[32mSuccessfully saved \e[1m#{out_file.inspect}\e[22m.\e[0m\n\n"
