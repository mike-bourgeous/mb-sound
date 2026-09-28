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
#
# Usage:
#     $0 [--decode] [--overwrite] input_audio matrix_file output_audio
#     $0 --list                     # lists the included matrices
#     $0 --show [--decode] matrix_file  # displays detailed matrix info

require 'bundler/setup'
require 'mb/sound'

MB::Sound.script(
  args: 0..3,
  list: [false, 'List the included matrices'],
  show: [false, 'Display detailed info for one matrix file'],
  decode: [false, 'Transpose and conjugate the matrix (encoder <-> decoder)'],
  overwrite: [false, '-f', 'Overwrite the output file'],
) { |args, p|
  if p.list
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

    next
  end

  if p.show
    abort 'Give one matrix file to --show' unless args.length == 1
    matrix_file = MB::Sound::ProcessingMatrix.find_file(args[0])

    m = MB::Sound::ProcessingMatrix.from_file(
      matrix_file,
      decode: p.decode
    )

    description = MB::U.read_header_comment(matrix_file)
    description[0] = "\e[1m#{description[0]}\e[0m"
    puts description.join

    puts "\n\e[1;36mTransposing matrix for decoding.\e[0m" if p.decode

    puts
    m.table
    puts

    next
  end

  abort 'Give an input file, a matrix file, and an output file (see --help)' unless args.length == 3
  in_file, mat_file, out_file = args

  abort "Input file #{in_file.inspect} not found (see --help)" unless File.readable?(in_file)

  m = MB::Sound::ProcessingMatrix.from_file(MB::Sound::ProcessingMatrix.find_file(mat_file), decode: p.decode)

  puts "\nProcessing \e[1;34m#{in_file.inspect}\e[0m through matrix \e[1;33m#{mat_file.inspect}\e[0m."
  puts "Expecting \e[1m#{m.input_channels}\e[0m input channel(s), producing \e[1m#{m.output_channels}\e[0m output channel(s)."
  puts "\n\e[1;36mTransposing matrix for decoding.\e[0m" if p.decode

  puts
  m.table
  puts

  MB::U.prevent_overwrite(out_file, prompt: true) unless p.overwrite

  input_stream = MB::Sound::FFMPEGInput.new(in_file, channels: m.input_channels)
  input = MB::Sound.analytic_signal(input_stream.read(input_stream.frames))
  input_stream.close

  if input_stream.info[:channels] != m.input_channels
    puts "\e[1mNote:\e[0;33m audio file originally had \e[1m#{input_stream.info[:channels]}\e[22m channel(s), not \e[1m#{m.input_channels}\e[0m."
  end

  # TODO: Somehow pass channel layout to FFMPEG
  output_stream = MB::Sound::FFMPEGOutput.new(out_file, sample_rate: input_stream.sample_rate, channels: m.output_channels)
  output = m.process(input)
  output = output.map { |v| v.respond_to?(:real) ? v.real : v }
  output = MB::Sound.normalize_max(output, -0.1.db)
  output_stream.write(output)
  output_stream.close

  puts "\n\e[32mSuccessfully saved \e[1m#{out_file.inspect}\e[22m.\e[0m\n\n"
}
