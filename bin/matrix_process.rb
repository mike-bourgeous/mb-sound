#!/usr/bin/env ruby
# Multiplies each sample of an audio file by a processing matrix to produce a
# new output file.  If the --decode flag is given, then the matrix is
# transposed and the complex conjugate is taken of all coefficients to turn an
# encoding matrix into a decoding matrix (or vice versa).
#
# The number of channels in the input file *should* match the number of columns
# in the processing matrix.  If not, then FFMPEG will try to upmix or downmix
# the number of channels to match.
#
# The number of rows in the matrix will determine the number of channels in the
# output file.
#
# The matrix file should be a CSV, TSV, JSON, or YAML file that contains a 1D
# or 2D array of numbers (real or complex).  See examples in the matrices/
# directory, or see MB::Sound::ProcessingMatrix.from_file, for more information
# about the matrix file format.

require 'bundler/setup'
require 'mb/sound'

USAGE = <<-EOF
\e[0;1mUsage:\e[0m
    \e[1m#{$0}\e[0m [--decode] [--overwrite] input_audio matrix_file output_audio
    \e[1m#{$0}\e[0m --help \e[36mto display help\e[0m
    \e[1m#{$0}\e[0m --list \e[36mto list included matrices\e[0m
    \e[1m#{$0}\e[0m --show [--decode] matrix_file \e[36mto display detailed matrix info\e[0m

#{MB::U.read_header_comment.join}
EOF

def usage
  puts USAGE
  exit 1
end

usage if ARGV.include?('--help')

if ARGV.include?('--list')
  puts

  matrices = MB::Sound::ProcessingMatrix.included_matrices.map { |m|
    name = Pathname(m).relative_path_from(MB::Sound::ProcessingMatrix::MATRIX_PATH)
    matrix = MB::Sound::ProcessingMatrix.from_file(m)
    [
      "\e[33m#{name}\e[0m",
      "\e[1;32m#{matrix.input_channels}\e[0m",
      "\e[1;34m#{matrix.output_channels}\e[0m",
      "\e[36m#{MB::U.read_header_comment(m)[0]&.strip}\e[0m"
    ]
  }

  puts "\e[1mBuilt-in matrices \e[0m(stored in \e[36m#{MB::Sound::ProcessingMatrix::MATRIX_PATH}\e[0m):\n\n"

  MB::U.table(
    matrices,
    header: [
      "\e[1;33mName\e[0m",
      "\e[1;32mIn\e[0m",
      "\e[1;34mOut\e[0m",
      "\e[1;36mDescription\e[0m"
    ],
    variable_width: true
  )

  puts

  exit 1
end

if ARGV[0] == '--show'
  decode = !!ARGV.delete('--decode')
  matrix_file = MB::Sound::ProcessingMatrix.find_file(ARGV[1])

  p = MB::Sound::ProcessingMatrix.from_file(
    matrix_file,
    decode: decode
  )

  description = MB::U.read_header_comment(matrix_file)
  description[0] = "\e[1m#{description[0]}\e[0m"
  puts description.join

  puts "\n\e[1;36mTransposing matrix for decoding.\e[0m" if decode

  puts
  p.table
  puts

  exit 0
end

overwrite = !!ARGV.delete('--overwrite')

case ARGV.length
when 3
  in_file, mat_file, out_file = ARGV
  decode = false

when 4
  usage if ARGV[0] != '--decode'

  _, in_file, mat_file, out_file = ARGV
  decode = true

else
  usage
end

raise "Input file #{in_file.inspect} not found.\n#{USAGE}" unless File.readable?(in_file)

p = MB::Sound::ProcessingMatrix.from_file(MB::Sound::ProcessingMatrix.find_file(mat_file), decode: decode)

puts "\nProcessing \e[1;34m#{in_file.inspect}\e[0m through matrix \e[1;33m#{mat_file.inspect}\e[0m."
puts "Expecting \e[1m#{p.input_channels}\e[0m input channel(s), producing \e[1m#{p.output_channels}\e[0m output channel(s)."
puts "\n\e[1;36mTransposing matrix for decoding.\e[0m" if decode

puts
p.table
puts

MB::U.prevent_overwrite(out_file, prompt: true) unless overwrite

input_stream = MB::Sound::FFMPEGInput.new(in_file, channels: p.input_channels)
input = MB::Sound.analytic_signal(input_stream.read(input_stream.frames))
input_stream.close

if input_stream.info[:channels] != p.input_channels
  puts "\e[1mNote:\e[0;33m audio file originally had \e[1m#{input_stream.info[:channels]}\e[22m channel(s), not \e[1m#{p.input_channels}\e[0m."
end

# TODO: Somehow pass channel layout to FFMPEG
output_stream = MB::Sound::FFMPEGOutput.new(out_file, sample_rate: input_stream.sample_rate, channels: p.output_channels)
output = p.process(input)
output = output.map { |v| v.respond_to?(:real) ? v.real : v }
output = MB::Sound.normalize_max(output, -0.1.db)
output_stream.write(output)
output_stream.close

puts "\n\e[32mSuccessfully saved \e[1m#{out_file.inspect}\e[22m.\e[0m\n\n"
