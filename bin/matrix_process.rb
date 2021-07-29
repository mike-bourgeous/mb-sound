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

MATRIX_PATH = File.expand_path('../matrices/', File.dirname(__FILE__))

USAGE = <<-EOF
\e[0;1mUsage:\e[0m
    \e[1m#{$0}\e[0m [--decode] [--overwrite] input_audio matrix_file output_audio
    \e[1m#{$0}\e[0m --help to display help
    \e[1m#{$0}\e[0m --list to list included matrices

#{MB::U.read_header_comment.join}
EOF

def usage
  puts USAGE
  exit 1
end

usage if ARGV.include?('--help')

if ARGV.include?('--list')
  puts

  matrices = Dir[File.join(MATRIX_PATH, '**', '*')].select { |m|
    File.file?(m)
  }.sort.map { |m|
    name = Pathname(m).relative_path_from(MATRIX_PATH)
    matrix = MB::Sound::ProcessingMatrix.from_file(m)
    [
      "\e[33m#{name}\e[0m",
      "\e[1;32m#{matrix.input_channels}\e[0m",
      "\e[1;34m#{matrix.output_channels}\e[0m",
      "\e[36m#{MB::U.read_header_comment(m)[0]&.strip}\e[0m"
    ]
  }

  puts "\e[1mBuilt-in matrices \e[0m(stored in \e[36m#{MATRIX_PATH}\e[0m):\n\n"

  MB::U.table(
    matrices,
    header: [
      "\e[1;33mName\e[0m", "\e[1;32mIn\e[0m", "\e[1;34mOut\e[0m", "\e[1;36mDescription\e[0m" ],
    variable_width: true
  )

  puts

  exit 1
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

# Check for an included matrix file in the gem directory (TODO: is there a
# stdlib method for checking if a path has no upward directory traversal?)
if mat_file[0] != '/' && mat_file[0] != '.' && !mat_file.split('/').include?(/^[.][.]?$/)
  included_mat_file = File.expand_path(File.join(MATRIX_PATH, mat_file))
  expanded_mat_file = File.expand_path(mat_file)

  if File.file?(mat_file) && File.file?(included_mat_file) && expanded_mat_file != included_mat_file
    # If an included matrix and a directly navigable file have the same name,
    # use the directly navigable file, but print a warning.
    puts "\e[1;33mWarning:\e[22m Ambiguous matrix filename matches included matrix.\e[0m"
    puts "\e[33mUsing \e[1m#{expanded_mat_file}\e[22m instead of included matrix \e[1m#{included_mat_file}\e[22m.\e[0m"
  elsif !File.file?(mat_file) && File.file?(included_mat_file)
    # If an included matrix was found and there is no directly navigable
    # matrix, use the included matrix.
    puts "\e[32mUsing included matrix \e[1m#{included_mat_file}\e[0m"
    mat_file = included_mat_file
  end
end

raise "Input file #{in_file.inspect} not found.\n#{USAGE}" unless File.readable?(in_file)
raise "Matrix file #{mat_file.inspect} not found.\n#{USAGE}" unless File.readable?(mat_file)

p = MB::Sound::ProcessingMatrix.from_file(mat_file, decode: decode)

puts "\nProcessing \e[1;34m#{in_file.inspect}\e[0m through matrix \e[1;36m#{mat_file.inspect}\e[0m."
puts "Expecting \e[1m#{p.input_channels}\e[0m input channel(s), producing \e[1m#{p.output_channels}\e[0m output channel(s)."
puts "\e[33mTransposing matrix for decoding.\e[0m" if decode

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
output_stream = MB::Sound::FFMPEGOutput.new(out_file, rate: input_stream.rate, channels: p.output_channels)
output = p.process(input)
output = output.map { |v| v.respond_to?(:real) ? v.real : v }
output_stream.write(output)
output_stream.close

puts "\n\e[32mSuccessfully saved \e[1m#{out_file.inspect}\e[22m.\e[0m\n\n"
